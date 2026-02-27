#!/bin/bash
# =============================================================================
# frOSt Build System v3.0
# =============================================================================
# Builds a complete frOSt bootable USB disk image:
#   1. Creates a Debian rootfs via debootstrap (with all packages)
#   2. Configures system (users, networking, NTP, hardware detection, browser)
#   3. Installs desktop environment (XFCE4 + picom + theming)
#   4. Assembles the x86-64 early init binary (bare-metal asm)
#   5. Compiles the Python init to standalone binary (Nuitka)
#   6. Builds the initramfs (asm + shell bootstrap + Python init + busybox + modules)
#   7. Creates a partitioned disk image with GRUB
#
# Init system: x86-64 assembly early_init -> shell bootstrap -> Python frost_init (from squashfs)
# USB removal triggers automatic clean shutdown via frost-usb-watchdog
#
# This is the single source of truth for the build.
#
# Requirements: debootstrap, nasm, grub, mtools, squashfs-tools, python3
# Must run as root inside Linux (WSL or native)
# =============================================================================

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
FROST_VERSION="3.0.0"
BUILD_DIR="/root/frost-build"
ROOTFS_DIR="${BUILD_DIR}/rootfs"
INITRAMFS_DIR="${BUILD_DIR}/initramfs"
IMAGE_FILE="${BUILD_DIR}/frost.img"
IMAGE_SIZE_MB=3072
EFI_SIZE_MB=256
ROOT_SIZE_MB=2000
DEBIAN_RELEASE="bookworm"
DEBIAN_MIRROR="http://deb.debian.org/debian"

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─── Logging ─────────────────────────────────────────────────────────────────
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
RESET='\033[0m'

log() { echo -e "${CYAN}[frOSt]${RESET} $1"; }
ok()  { echo -e "${GREEN}[OK]${RESET} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $1"; }
err() { echo -e "${RED}[ERROR]${RESET} $1"; exit 1; }

# ─── Chroot helpers ──────────────────────────────────────────────────────────
mount_chroot() {
    mount --bind /dev "${ROOTFS_DIR}/dev" 2>/dev/null || true
    mount --bind /dev/pts "${ROOTFS_DIR}/dev/pts" 2>/dev/null || true
    mount -t proc proc "${ROOTFS_DIR}/proc" 2>/dev/null || true
    mount -t sysfs sysfs "${ROOTFS_DIR}/sys" 2>/dev/null || true
    mount -t tmpfs tmpfs "${ROOTFS_DIR}/tmp" 2>/dev/null || true
}

umount_chroot() {
    umount -l "${ROOTFS_DIR}/tmp" 2>/dev/null || true
    umount -l "${ROOTFS_DIR}/sys" 2>/dev/null || true
    umount -l "${ROOTFS_DIR}/proc" 2>/dev/null || true
    umount -l "${ROOTFS_DIR}/dev/pts" 2>/dev/null || true
    umount -l "${ROOTFS_DIR}/dev" 2>/dev/null || true
}

# =============================================================================
# Step 0: Pre-flight checks
# =============================================================================
preflight() {
    log "Pre-flight checks..."
    [[ $EUID -eq 0 ]] || err "Must run as root"
    for cmd in debootstrap nasm mksquashfs grub-mkimage parted mkfs.fat mkfs.ext4 cpio; do
        command -v $cmd >/dev/null 2>&1 || err "Missing: $cmd"
    done
    ok "Dependencies found"
}

# =============================================================================
# Step 1: Debootstrap rootfs with all packages
# =============================================================================
build_rootfs() {
    log "Building Debian rootfs (${DEBIAN_RELEASE})..."
    umount_chroot
    rm -rf "${ROOTFS_DIR}"
    mkdir -p "${ROOTFS_DIR}"

    # All packages in one debootstrap call (apt unreliable in WSL chroot)
    debootstrap \
        --variant=minbase \
        --components=main,contrib,non-free,non-free-firmware \
        --include=systemd,systemd-sysv,systemd-timesyncd,udev,dbus,apt,\
python3,python3-minimal,python3-pil,\
iproute2,iputils-ping,net-tools,bash,coreutils,util-linux,mount,\
kmod,procps,passwd,login,adduser,sudo,locales,\
linux-image-amd64,grub-efi-amd64,grub-pc-bin,\
xfce4,xfce4-terminal,lightdm,lightdm-gtk-greeter,\
xorg,xserver-xorg-video-all,dbus-x11,at-spi2-core,policykit-1,\
xfce4-whiskermenu-plugin,xfce4-screenshooter,\
xfce4-power-manager,xfce4-taskmanager,\
mousepad,thunar-archive-plugin,file-roller,\
network-manager-gnome,\
wpasupplicant,iw,wireless-tools,rfkill,wireless-regdb,\
firmware-linux-free,firmware-iwlwifi,\
fonts-hack,fonts-liberation2,fonts-noto-color-emoji,\
conky-all,neofetch,htop,\
librsvg2-bin,\
pulseaudio,pavucontrol,\
gdisk,parted,pciutils,usbutils,\
picom,papirus-icon-theme,\
firefox-esr \
        "${DEBIAN_RELEASE}" \
        "${ROOTFS_DIR}" \
        "${DEBIAN_MIRROR}"

    ok "Debootstrap complete"
    configure_rootfs
}

# =============================================================================
# Step 2: Configure rootfs (users, networking, services, hardware)
# =============================================================================
configure_rootfs() {
    log "Configuring rootfs..."

    # ── Hostname / hosts ──
    echo "frost" > "${ROOTFS_DIR}/etc/hostname"
    cat > "${ROOTFS_DIR}/etc/hosts" << 'EOF'
127.0.0.1   localhost
127.0.1.1   frost
::1         localhost ip6-localhost ip6-loopback
EOF

    # ── Fstab ──
    cat > "${ROOTFS_DIR}/etc/fstab" << 'EOF'
tmpfs   /tmp    tmpfs   defaults,nosuid,nodev   0 0
tmpfs   /run    tmpfs   defaults,nosuid,nodev   0 0
EOF

    # ── Apt sources (main + contrib + non-free + firmware) ──
    cat > "${ROOTFS_DIR}/etc/apt/sources.list" << EOF
deb ${DEBIAN_MIRROR} ${DEBIAN_RELEASE} main contrib non-free non-free-firmware
deb ${DEBIAN_MIRROR} ${DEBIAN_RELEASE}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${DEBIAN_RELEASE}-security main contrib non-free non-free-firmware
EOF

    # ── Users ──
    chroot "${ROOTFS_DIR}" bash -c "
        echo 'root:frost' | chpasswd
        adduser --disabled-password --gecos 'frOSt User' frost 2>/dev/null || true
        echo 'frost:frost' | chpasswd
        usermod -aG sudo,video,audio,plugdev,netdev frost
    "
    cat > "${ROOTFS_DIR}/etc/sudoers.d/frost" << 'EOF'
frost ALL=(ALL) NOPASSWD: ALL
EOF
    chmod 440 "${ROOTFS_DIR}/etc/sudoers.d/frost"

    # ── Autologin on tty1 ──
    mkdir -p "${ROOTFS_DIR}/etc/systemd/system/getty@tty1.service.d"
    cat > "${ROOTFS_DIR}/etc/systemd/system/getty@tty1.service.d/autologin.conf" << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin frost --noclear %I $TERM
Type=idle
EOF

    # ── NetworkManager ──
    cat > "${ROOTFS_DIR}/etc/NetworkManager/NetworkManager.conf" << 'EOF'
[main]
plugins=ifupdown,keyfile
dns=default

[ifupdown]
managed=true

[device]
wifi.scan-rand-mac-address=no
EOF
    cat > "${ROOTFS_DIR}/etc/network/interfaces" << 'EOF'
source /etc/network/interfaces.d/*
auto lo
iface lo inet loopback
EOF

    # ── DNS fallback (NetworkManager overwrites on boot with DHCP DNS) ──
    cat > "${ROOTFS_DIR}/etc/resolv.conf" << 'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 9.9.9.9
EOF

    # ── NTP time sync ──
    cat > "${ROOTFS_DIR}/etc/systemd/timesyncd.conf" << 'EOF'
[Time]
NTP=0.debian.pool.ntp.org 1.debian.pool.ntp.org 2.debian.pool.ntp.org 3.debian.pool.ntp.org
FallbackNTP=0.pool.ntp.org 1.pool.ntp.org 2.pool.ntp.org
RootDistanceMaxSec=5
PollIntervalMinSec=32
PollIntervalMaxSec=2048
EOF

    # ── iwlwifi configuration ──
    cat > "${ROOTFS_DIR}/etc/modprobe.d/iwlwifi.conf" << 'EOF'
options iwlmvm power_scheme=1
EOF
    # ── Module autoload for WiFi stack ──
    cat > "${ROOTFS_DIR}/etc/modules-load.d/iwlwifi.conf" << 'EOF'
rfkill
cfg80211
mac80211
iwlwifi
iwlmvm
EOF

    # ── Locale ──
    chroot "${ROOTFS_DIR}" bash -c "
        echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen
        locale-gen 2>/dev/null || true
    "
    # ── Timezone ──
    chroot "${ROOTFS_DIR}" bash -c "
        ln -sf /usr/share/zoneinfo/UTC /etc/localtime
        echo 'UTC' > /etc/timezone
    "

    # ── OS Branding ──
    cat > "${ROOTFS_DIR}/etc/os-release" << EOF
PRETTY_NAME="frOSt ${FROST_VERSION} (Frozen Operating System)"
NAME="frOSt"
VERSION_ID="${FROST_VERSION}"
VERSION="${FROST_VERSION}"
ID=frost
ID_LIKE=debian
HOME_URL="https://github.com/frost-os"
BUG_REPORT_URL="https://github.com/frost-os/issues"
VARIANT="Desktop"
VARIANT_ID=desktop
EOF

    cat > "${ROOTFS_DIR}/etc/lsb-release" << EOF
DISTRIB_ID=frOSt
DISTRIB_RELEASE=${FROST_VERSION}
DISTRIB_CODENAME=frost
DISTRIB_DESCRIPTION="frOSt ${FROST_VERSION} (Frozen Operating System)"
EOF

    # /etc/issue - shown before login prompt
    cat > "${ROOTFS_DIR}/etc/issue" << 'EOF'

\e[1;36m  :::::::::: :::::::::   ::::::::   ::::::::  ::::::::::\e[0m
\e[1;36m  :+:        :+:    :+: :+:    :+: :+:    :+:    :+:   \e[0m
\e[1;36m  +:+        +:+    +:+ +:+    +:+ +:+           +:+   \e[0m
\e[1;36m  :#::+::#   +#++:++#:  +#+    +:+ +#++:++#++    +#+   \e[0m
\e[1;36m  +#+        +#+    +#+ +#+    +#+        +#+    +#+    \e[0m
\e[1;36m  #+#        #+#    #+# #+#    #+# #+#    #+#    #+#    \e[0m
\e[1;36m  ###        ###    ###  ########   ########     ###    \e[0m
\e[0m
\e[0;37m  Frozen Operating System\e[0m
\e[0;90m  \n (\l)\e[0m

EOF

    cat > "${ROOTFS_DIR}/etc/issue.net" << 'EOF'
frOSt - Frozen Operating System
EOF

    # ── MOTD ──
    cat > "${ROOTFS_DIR}/etc/motd" << 'EOF'

  [1;34m┌──────────────────────────────────────────────┐[0m
  [1;34m│[1;36m  ❄  frOSt - Frozen Operating System  ❄      [1;34m│[0m
  [1;34m└──────────────────────────────────────────────┘[0m

  [1;37mfrOSt v3.0[0m  [0;90m|[0m  [0;36mInit: [0;32masm + python[0m  [0;90m|[0m  [0;36mOverlay: [0;32mACTIVE[0m  [0;90m|[0m  [0;36mPersist: [0;32mON[0m
  [0;90mAll changes are transient unless persisted.[0m
  [1;33m⚡ USB watchdog active — pull USB to shutdown cleanly[0m

  [1;36mCommands:[0m
    [0;36mfrost-persist list[0m        - See persistent paths
    [0;36mfrost-persist add <path>[0m  - Persist a path
    [0;36mfrost-overlay status[0m      - Overlay info
    [0;36mfrost-wifi-diag[0m           - WiFi diagnostics

EOF

    ok "Base system configured"

    install_frost_tools
    install_services
}

# =============================================================================
# Strip bloat from rootfs (~500MB+ savings)
# =============================================================================
strip_bloat() {
    log "Stripping bloat from rootfs..."
    local saved=0
    local before after

    # ── Locales: keep only en_US (saves ~160MB) ──
    before=$(du -sm "${ROOTFS_DIR}/usr/share/locale/" 2>/dev/null | cut -f1)
    find "${ROOTFS_DIR}/usr/share/locale/" -mindepth 1 -maxdepth 1 -type d \
        ! -name 'en' ! -name 'en_US' ! -name 'en_GB' ! -name 'locale.alias' \
        -exec rm -rf {} + 2>/dev/null || true
    after=$(du -sm "${ROOTFS_DIR}/usr/share/locale/" 2>/dev/null | cut -f1)
    saved=$((saved + before - after))
    ok "Locales stripped: ${before}M -> ${after}M"

    # ── Docs and man pages (saves ~60MB) ──
    before=$(du -sm "${ROOTFS_DIR}/usr/share/doc/" "${ROOTFS_DIR}/usr/share/man/" 2>/dev/null | awk '{s+=$1}END{print s}')
    rm -rf "${ROOTFS_DIR}/usr/share/doc/"*
    rm -rf "${ROOTFS_DIR}/usr/share/man/"*
    rm -rf "${ROOTFS_DIR}/usr/share/info/"*
    rm -rf "${ROOTFS_DIR}/usr/share/lintian/"*
    mkdir -p "${ROOTFS_DIR}/usr/share/doc" "${ROOTFS_DIR}/usr/share/man"
    ok "Docs/man stripped: ${before}M saved"
    saved=$((saved + before))

    # ── Icon themes: keep only Papirus-Dark + hicolor (saves ~250MB) ──
    before=$(du -sm "${ROOTFS_DIR}/usr/share/icons/" 2>/dev/null | cut -f1)
    for theme in Papirus ePapirus ePapirus-Dark Papirus-Light Adwaita; do
        rm -rf "${ROOTFS_DIR}/usr/share/icons/${theme}" 2>/dev/null || true
    done
    after=$(du -sm "${ROOTFS_DIR}/usr/share/icons/" 2>/dev/null | cut -f1)
    saved=$((saved + before - after))
    ok "Icons stripped: ${before}M -> ${after}M"

    # ── GCC (not needed at runtime, saves ~32MB) ──
    rm -rf "${ROOTFS_DIR}/lib/gcc" 2>/dev/null || true

    # ── Perl (not needed for desktop use, saves ~21MB) ──
    # Keep perl binary but remove modules we don't need
    rm -rf "${ROOTFS_DIR}/usr/share/perl" 2>/dev/null || true

    # ── i18n data (saves ~17MB) ──
    rm -rf "${ROOTFS_DIR}/usr/share/i18n/locales/"* 2>/dev/null || true
    # Keep charmaps needed for en_US
    find "${ROOTFS_DIR}/usr/share/i18n/charmaps/" -type f \
        ! -name 'UTF-8.gz' ! -name 'ISO-8859-1.gz' ! -name 'ANSI*' \
        -delete 2>/dev/null || true

    # ── Poppler data (PDF rendering data, saves ~13MB) ──
    rm -rf "${ROOTFS_DIR}/usr/share/poppler" 2>/dev/null || true

    # ── Ghostscript (saves ~3MB) ──
    rm -rf "${ROOTFS_DIR}/usr/share/ghostscript" 2>/dev/null || true

    # ── Aspell (spell checker data, saves ~1.7MB) ──
    rm -rf "${ROOTFS_DIR}/lib/aspell" 2>/dev/null || true

    # ── GRUB modules in rootfs (already on EFI partition, saves ~22MB) ──
    rm -rf "${ROOTFS_DIR}/lib/grub" 2>/dev/null || true
    rm -rf "${ROOTFS_DIR}/usr/share/grub" 2>/dev/null || true

    # ── Boot directory (kernel/initrd already on EFI, saves ~46MB) ──
    # Save kernel to build dir first (needed for EFI partition later)
    local kver
    kver=$(ls "${ROOTFS_DIR}/lib/modules/" | head -1)
    local vmlinuz="${ROOTFS_DIR}/boot/vmlinuz-${kver}"
    [[ -f "${vmlinuz}" ]] || vmlinuz=$(find "${ROOTFS_DIR}/boot" -name 'vmlinuz-*' | head -1)
    if [[ -f "${vmlinuz}" ]]; then
        cp "${vmlinuz}" "${BUILD_DIR}/vmlinuz"
        ok "Kernel saved to build dir"
    fi
    rm -f "${ROOTFS_DIR}/boot/vmlinuz-"* 2>/dev/null || true
    rm -f "${ROOTFS_DIR}/boot/initrd.img-"* 2>/dev/null || true
    rm -f "${ROOTFS_DIR}/boot/System.map-"* 2>/dev/null || true
    rm -f "${ROOTFS_DIR}/boot/config-"* 2>/dev/null || true

    # ── Python cache (saves ~5MB) ──
    find "${ROOTFS_DIR}" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
    find "${ROOTFS_DIR}" -name '*.pyc' -delete 2>/dev/null || true

    # ── Misc cleanup ──
    rm -rf "${ROOTFS_DIR}/usr/share/help" 2>/dev/null || true
    rm -rf "${ROOTFS_DIR}/usr/share/groff" 2>/dev/null || true
    rm -rf "${ROOTFS_DIR}/usr/share/libwacom" 2>/dev/null || true
    rm -rf "${ROOTFS_DIR}/usr/include" 2>/dev/null || true
    rm -rf "${ROOTFS_DIR}/var/log/"* 2>/dev/null || true
    rm -rf "${ROOTFS_DIR}/var/cache/ldconfig/"* 2>/dev/null || true

    local total
    total=$(du -sm "${ROOTFS_DIR}" | cut -f1)
    ok "Bloat stripped (~${saved}M saved). Rootfs now: ${total}M"
}

# =============================================================================
# Install frOSt CLI tools
# =============================================================================
install_frost_tools() {
    log "Installing frOSt tools..."

    local bindir="${ROOTFS_DIR}/usr/local/bin"
    mkdir -p "${bindir}"

    for tool in frost-persist frost-overlay frost-config; do
        cp "${SRC_DIR}/tools/${tool}.py" "${bindir}/${tool}"
        chmod 755 "${bindir}/${tool}"
        if ! head -1 "${bindir}/${tool}" | grep -q '^#!'; then
            sed -i '1i#!/usr/bin/env python3' "${bindir}/${tool}"
        fi
    done

    # USB watchdog daemon
    cp "${SRC_DIR}/tools/frost-usb-watchdog.py" "${bindir}/frost-usb-watchdog"
    chmod 755 "${bindir}/frost-usb-watchdog"
    if ! head -1 "${bindir}/frost-usb-watchdog" | grep -q '^#!'; then
        sed -i '1i#!/usr/bin/env python3' "${bindir}/frost-usb-watchdog"
    fi

    local sbindir="${ROOTFS_DIR}/usr/local/sbin"
    mkdir -p "${sbindir}"
    cp "${SRC_DIR}/tools/frost-expand-persist.sh" "${sbindir}/frost-expand-persist"
    chmod 755 "${sbindir}/frost-expand-persist"

    mkdir -p "${ROOTFS_DIR}/etc/frost"
    ok "frOSt tools installed"
}

# =============================================================================
# Install systemd services (persist sync, auto-expand, hw detect, boot diag)
# =============================================================================
install_services() {
    log "Installing systemd services..."

    # ── Persistence sync (runs at shutdown) ──
    cat > "${ROOTFS_DIR}/etc/systemd/system/frost-sync.service" << 'EOF'
[Unit]
Description=frOSt Persistence Sync
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/frost-persist sync
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    # ── Auto-expand persistence partition ──
    cat > "${ROOTFS_DIR}/etc/systemd/system/frost-expand-persist.service" << 'EOF'
[Unit]
Description=Expand frOSt persistence partition to fill disk
DefaultDependencies=no
After=local-fs.target
Before=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/frost-expand-persist
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # ── Hardware detection service ──
    install_hwdetect

    # ── Boot diagnostics ──
    install_boot_diag

    # ── USB watchdog (shutdown on USB removal) ──
    cat > "${ROOTFS_DIR}/etc/systemd/system/frost-usb-watchdog.service" << 'EOF'
[Unit]
Description=frOSt USB Removal Watchdog
After=multi-user.target
Wants=frost-hwdetect.service

[Service]
Type=simple
ExecStart=/usr/local/bin/frost-usb-watchdog
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # Enable all services
    mount_chroot
    chroot "${ROOTFS_DIR}" bash -c "
        systemctl enable frost-sync.service 2>/dev/null || true
        systemctl enable frost-expand-persist.service 2>/dev/null || true
        systemctl enable frost-hwdetect.service 2>/dev/null || true
        systemctl enable frost-boot-diag.service 2>/dev/null || true
        systemctl enable frost-usb-watchdog.service 2>/dev/null || true
        systemctl enable systemd-timesyncd.service 2>/dev/null || true
        systemctl enable lightdm 2>/dev/null || true
        systemctl enable NetworkManager.service 2>/dev/null || true
        systemctl enable wpa_supplicant.service 2>/dev/null || true

        # Boot speed: disable services that block or slow boot
        systemctl disable NetworkManager-wait-online.service 2>/dev/null || true
        systemctl disable e2scrub_reap.service 2>/dev/null || true
        systemctl disable systemd-pstore.service 2>/dev/null || true
        systemctl disable remote-fs.target 2>/dev/null || true
        systemctl mask NetworkManager-wait-online.service 2>/dev/null || true
        systemctl mask plymouth-quit-wait.service 2>/dev/null || true
    "
    umount_chroot

    ok "Services installed"
}

# =============================================================================
# Hardware detection script + service
# =============================================================================
install_hwdetect() {
    cat > "${ROOTFS_DIR}/usr/local/sbin/frost-hwdetect" << 'HWDETECT'
#!/bin/bash
# frOSt Hardware Detection - loads kernel modules based on detected hardware
LOG_TAG="frost-hwdetect"
log() { echo "$1"; logger -t "$LOG_TAG" "$1" 2>/dev/null || true; }
log "=== frOSt Hardware Detection ==="

# WiFi
if lspci -d 8086: 2>/dev/null | grep -qi 'network\|wireless\|wi-fi'; then
    log "Intel WiFi detected"
    for m in rfkill cfg80211 mac80211 iwlwifi iwlmvm; do modprobe $m 2>/dev/null; done
    rfkill unblock wifi 2>/dev/null || true
fi
if lspci 2>/dev/null | grep -qi 'broadcom.*wireless\|BCM43'; then
    log "Broadcom WiFi detected"
    modprobe brcmfmac 2>/dev/null || modprobe wl 2>/dev/null || true
fi
if lspci 2>/dev/null | grep -qi 'realtek.*wireless\|RTL8'; then
    log "Realtek WiFi detected"
    modprobe rtw88_pci 2>/dev/null; modprobe rtw89_pci 2>/dev/null || true
fi
if lspci 2>/dev/null | grep -qi 'atheros\|qualcomm.*wireless\|QCA'; then
    log "Qualcomm/Atheros WiFi detected"
    modprobe ath9k 2>/dev/null; modprobe ath10k_pci 2>/dev/null; modprobe ath11k_pci 2>/dev/null || true
fi
if lspci 2>/dev/null | grep -qi 'mediatek.*wireless\|MT76'; then
    log "MediaTek WiFi detected"
    modprobe mt7921e 2>/dev/null || true
fi

# Ethernet
if lspci 2>/dev/null | grep -qi 'realtek.*ethernet\|RTL81'; then
    log "Realtek Ethernet detected"; modprobe r8169 2>/dev/null || true
fi
if lspci 2>/dev/null | grep -qi 'intel.*ethernet'; then
    log "Intel Ethernet detected"; modprobe e1000e 2>/dev/null; modprobe igc 2>/dev/null || true
fi

# GPU
if lspci -d 8086: 2>/dev/null | grep -qi 'VGA\|Display\|Graphics'; then
    log "Intel GPU detected"; modprobe i915 2>/dev/null || true
fi
if lspci 2>/dev/null | grep -qi 'nvidia'; then
    log "NVIDIA GPU detected"; modprobe nouveau 2>/dev/null || true
fi
if lspci 2>/dev/null | grep -qi 'amd.*vga\|amd.*display\|radeon'; then
    log "AMD GPU detected"; modprobe amdgpu 2>/dev/null || true
fi

# Audio
if lspci 2>/dev/null | grep -qi 'audio'; then
    log "Audio detected"
    modprobe snd_hda_intel 2>/dev/null; modprobe snd_hda_codec_realtek 2>/dev/null
    modprobe snd_hda_codec_hdmi 2>/dev/null || true
fi

# Storage
if lspci 2>/dev/null | grep -qi 'non-volatile\|nvme'; then
    log "NVMe detected"; modprobe nvme 2>/dev/null || true
fi
if lspci 2>/dev/null | grep -qi 'ahci\|sata'; then
    log "AHCI/SATA detected"; modprobe ahci 2>/dev/null || true
fi

# USB / Thunderbolt
if lspci 2>/dev/null | grep -qi 'xhci\|ehci'; then
    log "USB controllers detected"
    modprobe xhci_pci 2>/dev/null; modprobe usb_storage 2>/dev/null || true
fi
if lspci 2>/dev/null | grep -qi 'thunderbolt'; then
    log "Thunderbolt detected"; modprobe thunderbolt 2>/dev/null || true
fi

# Bluetooth
if lsusb 2>/dev/null | grep -qi 'bluetooth\|8087:'; then
    log "Bluetooth detected"
    modprobe btusb 2>/dev/null; modprobe btintel 2>/dev/null; modprobe bluetooth 2>/dev/null || true
fi

# I2C (touchpad)
if lspci 2>/dev/null | grep -qi 'smbus\|i2c'; then
    log "I2C/SMBus detected"; modprobe i2c_hid_acpi 2>/dev/null || true
fi

log "=== Hardware Detection Complete ==="
HWDETECT
    chmod 755 "${ROOTFS_DIR}/usr/local/sbin/frost-hwdetect"

    cat > "${ROOTFS_DIR}/etc/systemd/system/frost-hwdetect.service" << 'EOF'
[Unit]
Description=frOSt Hardware Detection
DefaultDependencies=no
After=systemd-modules-load.service systemd-udevd.service
Before=network-pre.target NetworkManager.service
Wants=systemd-udevd.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/frost-hwdetect
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

# =============================================================================
# Boot diagnostics service (writes logs to persist partition)
# =============================================================================
install_boot_diag() {
    cat > "${ROOTFS_DIR}/usr/local/sbin/frost-boot-diag" << 'DIAG'
#!/bin/bash
LOGDIR="/frost/persist/boot-logs"
mkdir -p "$LOGDIR" 2>/dev/null || { LOGDIR="/tmp/frost-boot-logs"; mkdir -p "$LOGDIR"; }
{
    echo "=== frOSt Boot Diagnostics $(date) ==="
    uname -a; echo "---"
    free -h; echo "---"
    df -h; echo "---"
    mount | grep -E 'overlay|tmpfs|frost'; echo "---"
    ip link show; ip addr show
} > "$LOGDIR/boot-diag.log" 2>&1
lspci > "$LOGDIR/lspci.log" 2>&1
lsusb > "$LOGDIR/lsusb.log" 2>&1
lsmod > "$LOGDIR/lsmod.log" 2>&1
dmesg > "$LOGDIR/dmesg-boot.log" 2>&1
journalctl -b --no-pager > "$LOGDIR/journal-boot.log" 2>&1
timedatectl status > "$LOGDIR/time-status.log" 2>&1
dpkg -l > "$LOGDIR/dpkg-list.log" 2>&1
DIAG
    chmod 755 "${ROOTFS_DIR}/usr/local/sbin/frost-boot-diag"

    cat > "${ROOTFS_DIR}/etc/systemd/system/frost-boot-diag.service" << 'EOF'
[Unit]
Description=frOSt Boot Diagnostics
After=multi-user.target NetworkManager.service frost-hwdetect.service

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 10
ExecStart=/usr/local/sbin/frost-boot-diag
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

# =============================================================================
# Step 3: Install desktop environment and theme
# =============================================================================
install_desktop() {
    log "Installing desktop theme..."

    # ── Wallpaper ──
    mkdir -p "${ROOTFS_DIR}/usr/share/backgrounds/frost"
    cp "${SRC_DIR}/desktop/wallpaper.svg" "${ROOTFS_DIR}/usr/share/backgrounds/frost/"
    cp "${SRC_DIR}/desktop/frost-logo.svg" "${ROOTFS_DIR}/usr/share/backgrounds/frost/"

    mount_chroot

    # Generate wallpaper PNG (procedural cyberpunk frost theme)
    chroot "${ROOTFS_DIR}" python3 << 'WALLPAPER_PY'
from PIL import Image, ImageDraw
import math, random
random.seed(42)
W, H = 1920, 1080
img = Image.new('RGB', (W, H), (8, 16, 32))
draw = ImageDraw.Draw(img)
# Dark gradient background
for y in range(H):
    r = int(8 + 6 * (y / H))
    g = int(16 + 12 * (y / H))
    b = int(32 + 20 * (y / H))
    draw.line([(0, y), (W, y)], fill=(r, g, b))
# Subtle grid
for x in range(0, W, 60):
    draw.line([(x, 0), (x, H)], fill=(15, 30, 55), width=1)
for y in range(0, H, 60):
    draw.line([(0, y), (W, y)], fill=(15, 30, 55), width=1)
# Aurora streaks
for _ in range(8):
    y0 = random.randint(100, 500)
    for x in range(W):
        y = y0 + int(40 * math.sin(x * 0.008 + random.random()))
        alpha = int(20 + 15 * math.sin(x * 0.003))
        c = random.choice([(0, alpha, alpha*2), (0, int(alpha*1.5), alpha)])
        draw.point((x, y), fill=c)
# Particle stars
for _ in range(200):
    x, y = random.randint(0, W), random.randint(0, H)
    b = random.randint(60, 180)
    s = random.choice([1, 1, 1, 2])
    draw.ellipse([x, y, x+s, y+s], fill=(b, b+20, b+40))
# Frost crystal (center-bottom)
cx, cy = W//2, H - 200
for angle in range(0, 360, 60):
    rad = math.radians(angle)
    for length in range(40, 120, 10):
        ex = cx + int(length * math.cos(rad))
        ey = cy + int(length * math.sin(rad))
        draw.line([(cx, cy), (ex, ey)], fill=(0, 100 + length, 180 + min(length, 75)), width=1)
        # Branch
        if length > 60:
            for ba in [-30, 30]:
                brad = math.radians(angle + ba)
                blen = (length - 60) // 2
                bx = ex + int(blen * math.cos(brad))
                by = ey + int(blen * math.sin(brad))
                draw.line([(ex, ey), (bx, by)], fill=(0, 80 + length, 160 + min(length, 75)), width=1)
img.save('/usr/share/backgrounds/frost/wallpaper.png')
print('Wallpaper generated: 1920x1080')
WALLPAPER_PY

    # Convert logo SVG to PNG
    chroot "${ROOTFS_DIR}" bash -c "
        if command -v rsvg-convert >/dev/null 2>&1; then
            rsvg-convert -w 128 -h 128 /usr/share/backgrounds/frost/frost-logo.svg \
                -o /usr/share/backgrounds/frost/frost-logo.png
        fi
    "

    umount_chroot

    # ── LightDM ──
    cp "${SRC_DIR}/desktop/lightdm/lightdm.conf" "${ROOTFS_DIR}/etc/lightdm/"
    cp "${SRC_DIR}/desktop/lightdm/lightdm-gtk-greeter.conf" "${ROOTFS_DIR}/etc/lightdm/"
    mkdir -p "${ROOTFS_DIR}/var/lib/lightdm/data"

    # ── XFCE4 configs (system-wide defaults + frost user) ──
    local xdg_xfce="${ROOTFS_DIR}/etc/xdg/xfce4"
    local user_xfce="${ROOTFS_DIR}/home/frost/.config/xfce4"

    mkdir -p "${xdg_xfce}/xfconf/xfce-perchannel-xml" "${xdg_xfce}/terminal"
    mkdir -p "${user_xfce}/xfconf/xfce-perchannel-xml" "${user_xfce}/terminal"

    cp "${SRC_DIR}/desktop/xfce4/xfconf/xfce-perchannel-xml/"*.xml "${xdg_xfce}/xfconf/xfce-perchannel-xml/"
    cp "${SRC_DIR}/desktop/xfce4/xfconf/xfce-perchannel-xml/"*.xml "${user_xfce}/xfconf/xfce-perchannel-xml/"
    cp "${SRC_DIR}/desktop/xfce4/terminal/terminalrc" "${xdg_xfce}/terminal/"
    cp "${SRC_DIR}/desktop/xfce4/terminal/terminalrc" "${user_xfce}/terminal/"

    # ── Picom compositor ──
    local user_picom="${ROOTFS_DIR}/home/frost/.config/picom"
    mkdir -p "${user_picom}"
    cp "${SRC_DIR}/desktop/picom/picom.conf" "${user_picom}/"

    # ── GTK3 theme overlay ──
    local user_gtk="${ROOTFS_DIR}/home/frost/.config/gtk-3.0"
    local sys_gtk="${ROOTFS_DIR}/etc/gtk-3.0"
    mkdir -p "${user_gtk}" "${sys_gtk}"
    cp "${SRC_DIR}/desktop/gtk-3.0/gtk.css" "${user_gtk}/"
    cp "${SRC_DIR}/desktop/gtk-3.0/gtk.css" "${sys_gtk}/"

    # ── Conky ──
    cp "${SRC_DIR}/desktop/conky/conky.conf" "${ROOTFS_DIR}/etc/frost/"

    # ── Autostart entries ──
    local user_autostart="${ROOTFS_DIR}/home/frost/.config/autostart"
    local sys_autostart="${ROOTFS_DIR}/etc/xdg/autostart"
    mkdir -p "${user_autostart}" "${sys_autostart}"
    cp "${SRC_DIR}/desktop/autostart/conky.desktop" "${user_autostart}/"
    cp "${SRC_DIR}/desktop/autostart/conky.desktop" "${sys_autostart}/"
    cp "${SRC_DIR}/desktop/autostart/picom.desktop" "${user_autostart}/"
    cp "${SRC_DIR}/desktop/autostart/picom.desktop" "${sys_autostart}/"

    # ── Neofetch ──
    local user_neofetch="${ROOTFS_DIR}/home/frost/.config/neofetch"
    mkdir -p "${user_neofetch}"
    cp "${SRC_DIR}/desktop/neofetch/config.conf" "${ROOTFS_DIR}/etc/frost/neofetch.conf"
    cp "${SRC_DIR}/desktop/neofetch/config.conf" "${user_neofetch}/"
    cp "${SRC_DIR}/desktop/neofetch/frost-ascii" "${user_neofetch}/"

    # ── Shell prompt ──
    cp "${SRC_DIR}/desktop/bashrc-frost" "${ROOTFS_DIR}/etc/profile.d/frost-prompt.sh"
    chmod 644 "${ROOTFS_DIR}/etc/profile.d/frost-prompt.sh"

    # ── Icons ──
    mkdir -p "${ROOTFS_DIR}/usr/share/icons/hicolor/128x128/apps"
    mkdir -p "${ROOTFS_DIR}/usr/share/icons/hicolor/scalable/apps"
    cp "${SRC_DIR}/desktop/frost-logo.svg" "${ROOTFS_DIR}/usr/share/icons/hicolor/scalable/apps/"
    [ -f "${ROOTFS_DIR}/usr/share/backgrounds/frost/frost-logo.png" ] && \
        cp "${ROOTFS_DIR}/usr/share/backgrounds/frost/frost-logo.png" \
           "${ROOTFS_DIR}/usr/share/icons/hicolor/128x128/apps/"

    # ── Fix ownership ──
    chroot "${ROOTFS_DIR}" bash -c "chown -R frost:frost /home/frost 2>/dev/null || true"

    # ── Clean apt cache ──
    chroot "${ROOTFS_DIR}" bash -c "
        apt-get clean
        rm -rf /var/cache/apt/archives/*.deb /tmp/* /var/tmp/*
    "

    ok "Desktop themed"
}

# =============================================================================
# Step 4: Assemble x86-64 early init binary
# =============================================================================
build_asm() {
    log "Assembling early init stub..."
    local asm_src="${SRC_DIR}/boot/asm/early_init.asm"
    [[ -f "${asm_src}" ]] || err "ASM source not found: ${asm_src}"
    nasm -f elf64 -o "${BUILD_DIR}/early_init.o" "${asm_src}"
    ld -o "${BUILD_DIR}/early_init" "${BUILD_DIR}/early_init.o" --oformat=elf64-x86-64 -e _start --static
    strip --strip-all "${BUILD_DIR}/early_init" 2>/dev/null || true
    ok "Early init built ($(stat -c%s "${BUILD_DIR}/early_init") bytes)"
}

# =============================================================================
# Step 5: Build initramfs
# =============================================================================
build_initramfs() {
    log "Building initramfs..."
    rm -rf "${INITRAMFS_DIR}"
    mkdir -p "${INITRAMFS_DIR}"/{bin,sbin,usr/bin,usr/sbin,lib,lib64,dev,proc,sys,etc,run,tmp,frost}

    # ── Busybox ──
    if command -v busybox >/dev/null 2>&1; then
        cp "$(command -v busybox)" "${INITRAMFS_DIR}/bin/busybox"
    elif [[ -f /bin/busybox ]]; then
        cp /bin/busybox "${INITRAMFS_DIR}/bin/busybox"
    else
        apt-get install -y -qq busybox-static 2>/dev/null || true
        cp /bin/busybox "${INITRAMFS_DIR}/bin/busybox" 2>/dev/null || err "No busybox found"
    fi
    chmod 755 "${INITRAMFS_DIR}/bin/busybox"

    # Busybox symlinks
    for cmd in sh ash mount umount mkdir cat echo ls cp mv rm ln chmod chown \
               mknod switch_root pivot_root sleep grep sed awk printf \
               mountpoint findfs blkid losetup readlink tr sort touch \
               rmdir basename dirname head tail cut mdev find uname wc; do
        ln -sf busybox "${INITRAMFS_DIR}/bin/${cmd}" 2>/dev/null || true
    done
    for cmd in modprobe insmod switch_root pivot_root blkid; do
        ln -sf ../bin/busybox "${INITRAMFS_DIR}/sbin/${cmd}" 2>/dev/null || true
    done

    # ── Assembly early init binary ──
    cp "${BUILD_DIR}/early_init" "${INITRAMFS_DIR}/early_init"
    chmod 755 "${INITRAMFS_DIR}/early_init"

    # ── Python init script (used from squashfs via dynamic linker) ──
    cp "${SRC_DIR}/initramfs/frost_init.py" "${INITRAMFS_DIR}/frost_init.py"
    chmod 755 "${INITRAMFS_DIR}/frost_init.py"
    ok "Python init script installed"

    # ── /init shell bootstrap (kernel executes this) ──
    # Uses the full init script from source, which handles:
    #   asm early_init -> modules -> devices -> squashfs -> Python handoff
    cp "${SRC_DIR}/initramfs/init" "${INITRAMFS_DIR}/init"
    chmod 755 "${INITRAMFS_DIR}/init"

    # ── Python tools (copied into merged root during boot) ──
    cp "${SRC_DIR}/tools/frost-persist.py" "${INITRAMFS_DIR}/frost-persist.py"
    cp "${SRC_DIR}/tools/frost-overlay.py" "${INITRAMFS_DIR}/frost-overlay.py"
    cp "${SRC_DIR}/tools/frost-config.py"  "${INITRAMFS_DIR}/frost-config.py"

    # ── Device nodes ──
    mknod -m 622 "${INITRAMFS_DIR}/dev/console" c 5 1 2>/dev/null || true
    mknod -m 666 "${INITRAMFS_DIR}/dev/null"    c 1 3 2>/dev/null || true
    mknod -m 666 "${INITRAMFS_DIR}/dev/zero"    c 1 5 2>/dev/null || true
    mknod -m 666 "${INITRAMFS_DIR}/dev/tty"     c 5 0 2>/dev/null || true

    # ── Kernel modules ──
    copy_kernel_modules

    # ── Pack cpio ──
    log "Packing initramfs..."
    cd "${INITRAMFS_DIR}"
    find . | cpio -o -H newc 2>/dev/null | gzip -9 > "${BUILD_DIR}/initramfs.cpio.gz"
    ok "Initramfs: $(du -h "${BUILD_DIR}/initramfs.cpio.gz" | cut -f1)"
}

# =============================================================================
# Copy kernel modules for initramfs
# =============================================================================
copy_kernel_modules() {
    local kver
    kver=$(ls "${ROOTFS_DIR}/lib/modules/" | head -1)
    [[ -z "${kver}" ]] && { warn "No kernel modules found"; return; }

    local mod_src="${ROOTFS_DIR}/lib/modules/${kver}"
    local mod_dst="${INITRAMFS_DIR}/lib/modules/${kver}"
    mkdir -p "${mod_dst}"

    # Copy driver directories needed for early boot
    for subdir in drivers/ata drivers/scsi drivers/virtio drivers/block \
                  drivers/usb/common drivers/usb/storage drivers/usb/host drivers/usb/core \
                  drivers/hid \
                  drivers/gpu/drm/bochs drivers/gpu/drm/virtio \
                  drivers/gpu/drm/simpledrm drivers/gpu/drm/tiny \
                  fs/overlayfs fs/squashfs fs/ext4 fs/fat fs/nls fs/jbd2 \
                  block lib crypto arch/x86/crypto; do
        if [[ -d "${mod_src}/kernel/${subdir}" ]]; then
            mkdir -p "${mod_dst}/kernel/${subdir}"
            cp -r "${mod_src}/kernel/${subdir}"/* "${mod_dst}/kernel/${subdir}/" 2>/dev/null || true
        fi
    done

    # Individual modules that may live elsewhere
    for pat in "overlay.ko*" "squashfs.ko*" "loop.ko*" "virtio*.ko*" \
               "libata.ko*" "ahci.ko*" "sd_mod.ko*" "scsi_mod.ko*" \
               "ext4.ko*" "jbd2.ko*" "crc*.ko*" "mbcache.ko*" \
               "drm.ko*" "drm_kms_helper.ko*" "simpledrm.ko*"; do
        find "${mod_src}" -name "${pat}" 2>/dev/null | while read -r f; do
            local rel="${f#${mod_src}/}"
            local d="${mod_dst}/$(dirname "$rel")"
            mkdir -p "$d"
            cp "$f" "$d/" 2>/dev/null || true
        done
    done

    cp "${mod_src}/modules."* "${mod_dst}/" 2>/dev/null || true
    depmod -b "${INITRAMFS_DIR}" "${kver}" 2>/dev/null || true

    local cnt
    cnt=$(find "${mod_dst}" -name '*.ko*' 2>/dev/null | wc -l)
    ok "${cnt} kernel modules for ${kver}"
}

# =============================================================================
# Step 6: Create the disk image
# =============================================================================
build_image() {
    log "Creating disk image (${IMAGE_SIZE_MB}MB)..."
    dd if=/dev/zero of="${IMAGE_FILE}" bs=1M count=0 seek="${IMAGE_SIZE_MB}" 2>/dev/null

    parted -s "${IMAGE_FILE}" \
        mklabel gpt \
        mkpart "EFI" fat32 1MiB ${EFI_SIZE_MB}MiB \
        set 1 esp on \
        mkpart "FROST_ROOT" ext4 ${EFI_SIZE_MB}MiB $((EFI_SIZE_MB + ROOT_SIZE_MB))MiB \
        mkpart "FROST_PERSIST" ext4 $((EFI_SIZE_MB + ROOT_SIZE_MB))MiB 100%

    local loop_dev
    loop_dev=$(losetup --show -fP "${IMAGE_FILE}")
    sleep 1; partprobe "${loop_dev}" 2>/dev/null || true; sleep 1

    mkfs.fat -F32 -n "EFI" "${loop_dev}p1"
    mkfs.ext4 -L "FROST_ROOT" -q "${loop_dev}p2"
    mkfs.ext4 -L "FROST_PERSIST" -q "${loop_dev}p3"

    local mnt="${BUILD_DIR}/mnt"
    mkdir -p "${mnt}"/{efi,root,persist}

    # ── EFI partition ──
    mount "${loop_dev}p1" "${mnt}/efi"
    populate_efi "${mnt}/efi" "${loop_dev}"

    # ── Root partition (squashfs) ──
    mount "${loop_dev}p2" "${mnt}/root"
    populate_root "${mnt}/root"

    # ── Persistence partition ──
    mount "${loop_dev}p3" "${mnt}/persist"
    populate_persist "${mnt}/persist"

    sync
    umount "${mnt}/persist" "${mnt}/root" "${mnt}/efi"
    losetup -d "${loop_dev}"

    ok "Image: ${IMAGE_FILE} ($(du -h "${IMAGE_FILE}" | cut -f1))"
}

# =============================================================================
# Populate EFI partition
# =============================================================================
populate_efi() {
    local efi_dir="$1" loop_dev="$2"
    local vmlinuz

    # Kernel was saved to build dir by strip_bloat, or is still in rootfs
    if [[ -f "${BUILD_DIR}/vmlinuz" ]]; then
        vmlinuz="${BUILD_DIR}/vmlinuz"
    else
        local kver
        kver=$(ls "${ROOTFS_DIR}/lib/modules/" | head -1)
        vmlinuz="${ROOTFS_DIR}/boot/vmlinuz-${kver}"
        [[ -f "${vmlinuz}" ]] || vmlinuz=$(find "${ROOTFS_DIR}/boot" -name 'vmlinuz-*' | head -1)
    fi
    [[ -f "${vmlinuz}" ]] || err "Kernel not found"

    mkdir -p "${efi_dir}/EFI/BOOT" "${efi_dir}/boot/grub"
    cp "${vmlinuz}" "${efi_dir}/boot/vmlinuz"
    cp "${BUILD_DIR}/initramfs.cpio.gz" "${efi_dir}/boot/initramfs.img"

    grub-mkimage \
        -o "${efi_dir}/EFI/BOOT/BOOTX64.EFI" \
        -O x86_64-efi -p /boot/grub \
        part_gpt part_msdos fat ext2 normal boot linux \
        configfile loopback chain efifwsetup efi_gop \
        efi_uga ls search search_label search_fs_uuid \
        search_fs_file gfxterm gfxterm_background \
        gfxterm_menu test all_video loadenv echo

    grub-install --target=i386-pc --boot-directory="${efi_dir}/boot" \
        --modules="part_gpt part_msdos fat ext2 normal boot linux configfile search search_label" \
        "${loop_dev}" 2>/dev/null || warn "BIOS GRUB failed (EFI-only)"

    cat > "${efi_dir}/boot/grub/grub.cfg" << 'GRUBCFG'
set timeout=3
set default=0
set color_normal=cyan/black
set color_highlight=white/blue

# frOSt - Frozen Operating System
# Init: x86-64 asm + compiled Python

menuentry "frOSt Desktop" {
    linux /boot/vmlinuz root=LABEL=FROST_ROOT ro quiet splash loglevel=3
    initrd /boot/initramfs.img
}

menuentry "frOSt Console" {
    linux /boot/vmlinuz root=LABEL=FROST_ROOT ro quiet systemd.unit=multi-user.target
    initrd /boot/initramfs.img
}

menuentry "frOSt Recovery" {
    linux /boot/vmlinuz root=LABEL=FROST_ROOT ro single
    initrd /boot/initramfs.img
}

menuentry "frOSt Debug" {
    linux /boot/vmlinuz root=LABEL=FROST_ROOT ro debug loglevel=7
    initrd /boot/initramfs.img
}
GRUBCFG

    ok "EFI partition populated"
}

# =============================================================================
# Populate root partition (squashfs)
# =============================================================================
populate_root() {
    local root_dir="$1"
    log "Creating squashfs..."
    mksquashfs "${ROOTFS_DIR}" "${root_dir}/rootfs.squashfs" \
        -comp xz -Xdict-size 100% -Xbcj x86 -b 1M -no-xattrs -quiet 2>/dev/null || \
    mksquashfs "${ROOTFS_DIR}" "${root_dir}/rootfs.squashfs" \
        -comp xz -no-xattrs -quiet 2>/dev/null || \
    mksquashfs "${ROOTFS_DIR}" "${root_dir}/rootfs.squashfs" \
        -comp gzip -no-xattrs -quiet
    ok "Squashfs: $(du -h "${root_dir}/rootfs.squashfs" | cut -f1)"
}

# =============================================================================
# Populate persistence partition
# =============================================================================
populate_persist() {
    local persist_dir="$1"
    mkdir -p "${persist_dir}/data"
    cat > "${persist_dir}/frost-persist.json" << 'EOF'
{
  "version": 1,
  "persistent_paths": [
    "/etc/frost",
    "/home",
    "/var/lib/apt",
    "/var/cache/apt",
    "/etc/NetworkManager/system-connections",
    "/etc/hostname",
    "/etc/hosts"
  ],
  "persistent_packages": [],
  "persistent_services": [],
  "user_settings": {
    "auto_persist_home": true,
    "persist_logs": false,
    "persist_tmp": false
  }
}
EOF
    ok "Persistence initialized"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo -e "${CYAN}"
    echo '  :::::::::: :::::::::   ::::::::   ::::::::  ::::::::::'
    echo '  :+:        :+:    :+: :+:    :+: :+:    :+:    :+:   '
    echo '  +:+        +:+    +:+ +:+    +:+ +:+           +:+   '
    echo '  :#::+::#   +#++:++#:  +#+    +:+ +#++:++#++    +#+   '
    echo '  +#+        +#+    +#+ +#+    +#+        +#+    +#+    '
    echo '  #+#        #+#    #+# #+#    #+# #+#    #+#    #+#    '
    echo '  ###        ###    ###  ########   ########     ###    '
    echo -e "${RESET}"
    echo "frOSt Build System v${FROST_VERSION}"
    echo "Init: x86-64 asm + Python (from squashfs)"
    echo "======================================"
    echo ""

    rm -rf "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}"

    preflight
    build_rootfs
    install_desktop
    strip_bloat
    build_asm
    build_initramfs
    build_image

    # Copy to Windows filesystem if running in WSL
    if [ -d "/mnt/c/Users/thoma/Documents/frOSt" ]; then
        log "Copying image to Windows filesystem..."
        cp "${IMAGE_FILE}" "/mnt/c/Users/thoma/Documents/frOSt/frost.img"
        ok "Image copied to Windows"
    fi

    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════${RESET}"
    echo -e "${GREEN} frOSt build complete!${RESET}"
    echo -e "${GREEN} Image: ${IMAGE_FILE}${RESET}"
    echo -e "${GREEN} Size:  $(du -h "${IMAGE_FILE}" | cut -f1)${RESET}"
    echo -e "${GREEN}═══════════════════════════════════════════${RESET}"
}

main "$@"
