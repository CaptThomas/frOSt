#!/bin/bash
# =============================================================================
# frOSt Build System - Master Build Script
# =============================================================================
# Builds a complete frOSt bootable USB disk image:
#   1. Creates a minimal Debian rootfs via debootstrap
#   2. Assembles the x86-64 early init binary
#   3. Builds the initramfs (asm stub + shell init + busybox)
#   4. Creates a partitioned disk image with GRUB
#   5. Packs everything into a bootable image
#
# Requirements: debootstrap, nasm, grub, mtools, squashfs-tools, python3
# Must run as root inside Linux (WSL or native)
# =============================================================================

set -euo pipefail

# Configuration
FROST_VERSION="1.0.0"
BUILD_DIR="/root/frost-build"
ROOTFS_DIR="${BUILD_DIR}/rootfs"
INITRAMFS_DIR="${BUILD_DIR}/initramfs"
IMAGE_FILE="${BUILD_DIR}/frost.img"
IMAGE_SIZE_MB=4096
EFI_SIZE_MB=256
ROOT_SIZE_MB=2400
DEBIAN_RELEASE="bookworm"
DEBIAN_MIRROR="http://deb.debian.org/debian"

# Source directory (where this script lives)
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

# Colors
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
RESET='\033[0m'

log() { echo -e "${CYAN}[frOSt-build]${RESET} $1"; }
ok()  { echo -e "${GREEN}[OK]${RESET} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $1"; }
err() { echo -e "${RED}[ERROR]${RESET} $1"; exit 1; }

# =============================================================================
# Step 0: Pre-flight checks
# =============================================================================
preflight() {
    log "Running pre-flight checks..."

    [[ $EUID -eq 0 ]] || err "Must run as root (use sudo)"

    for cmd in debootstrap nasm mksquashfs grub-mkimage parted mkfs.fat mkfs.ext4 cpio; do
        command -v $cmd >/dev/null 2>&1 || err "Missing required command: $cmd"
    done

    ok "All dependencies found"
}

# =============================================================================
# Step 1: Create Debian rootfs via debootstrap
# =============================================================================
build_rootfs() {
    log "Building Debian rootfs (${DEBIAN_RELEASE})..."

    # Clean up any stale mounts from a previous failed build
    umount -l "${ROOTFS_DIR}/dev/pts" 2>/dev/null || true
    umount -l "${ROOTFS_DIR}/dev" 2>/dev/null || true
    umount -l "${ROOTFS_DIR}/proc" 2>/dev/null || true
    umount -l "${ROOTFS_DIR}/sys" 2>/dev/null || true
    umount -l "${ROOTFS_DIR}/tmp" 2>/dev/null || true

    rm -rf "${ROOTFS_DIR}"
    mkdir -p "${ROOTFS_DIR}"

    # Debootstrap with all packages (including desktop)
    # NOTE: All packages must be in --include because apt-get doesn't work
    # reliably in chroot under WSL2 (apt HTTP method hangs)
    debootstrap \
        --variant=minbase \
        --include=systemd,systemd-sysv,udev,dbus,apt,python3,python3-minimal,\
iproute2,iputils-ping,net-tools,bash,coreutils,util-linux,mount,\
kmod,procps,passwd,login,adduser,sudo,locales,\
linux-image-amd64,grub-efi-amd64,grub-pc-bin,\
xfce4,xfce4-terminal,lightdm,lightdm-gtk-greeter,\
xorg,xserver-xorg-video-all,dbus-x11,at-spi2-core,\
xfce4-whiskermenu-plugin,xfce4-screenshooter,\
xfce4-power-manager,xfce4-taskmanager,\
mousepad,thunar-archive-plugin,file-roller,\
network-manager-gnome,\
fonts-hack,fonts-liberation2,\
conky-all,neofetch,htop,\
librsvg2-bin,\
pulseaudio,pavucontrol \
        "${DEBIAN_RELEASE}" \
        "${ROOTFS_DIR}" \
        "${DEBIAN_MIRROR}"

    ok "Debootstrap complete"

    # Configure the rootfs
    configure_rootfs
}

# =============================================================================
# Configure the rootfs
# =============================================================================
configure_rootfs() {
    log "Configuring rootfs..."

    # Set hostname
    echo "frost" > "${ROOTFS_DIR}/etc/hostname"

    # Set hosts
    cat > "${ROOTFS_DIR}/etc/hosts" << 'HOSTS'
127.0.0.1   localhost
127.0.1.1   frost
::1         localhost ip6-localhost ip6-loopback
HOSTS

    # Set up fstab - minimal since overlay handles most
    cat > "${ROOTFS_DIR}/etc/fstab" << 'FSTAB'
# frOSt filesystem table
# Most filesystems are managed by the overlay system
# This file is overridden during boot by the initramfs
tmpfs   /tmp    tmpfs   defaults,nosuid,nodev   0 0
tmpfs   /run    tmpfs   defaults,nosuid,nodev   0 0
FSTAB

    # Configure apt sources
    cat > "${ROOTFS_DIR}/etc/apt/sources.list" << SOURCES
deb ${DEBIAN_MIRROR} ${DEBIAN_RELEASE} main contrib non-free non-free-firmware
deb ${DEBIAN_MIRROR} ${DEBIAN_RELEASE}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${DEBIAN_RELEASE}-security main contrib non-free non-free-firmware
SOURCES

    # Set root password to 'frost'
    chroot "${ROOTFS_DIR}" bash -c "echo 'root:frost' | chpasswd"

    # Create frost user
    chroot "${ROOTFS_DIR}" bash -c "
        adduser --disabled-password --gecos 'frOSt User' frost 2>/dev/null || true
        echo 'frost:frost' | chpasswd
        usermod -aG sudo frost
    "

    # Configure sudo for frost user
    cat > "${ROOTFS_DIR}/etc/sudoers.d/frost" << 'SUDOERS'
frost ALL=(ALL) NOPASSWD: ALL
SUDOERS
    chmod 440 "${ROOTFS_DIR}/etc/sudoers.d/frost"

    # Enable auto-login on tty1
    mkdir -p "${ROOTFS_DIR}/etc/systemd/system/getty@tty1.service.d"
    cat > "${ROOTFS_DIR}/etc/systemd/system/getty@tty1.service.d/autologin.conf" << 'AUTOLOGIN'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin frost --noclear %I $TERM
Type=idle
AUTOLOGIN

    # Install frOSt tools
    install_frost_tools

    # Configure login message
    cat > "${ROOTFS_DIR}/etc/motd" << 'MOTD'

 [0;36m     *        [0m
 [0;36m    /|\       [0m
 [0;36m   / | \      [0m
 [0;36m--/  |  \--   [0;37m  __       ___  ____  _   [0m
 [0;36m\  | /  \  [0;37m / _|_ __ / _ \/ ___|| |_ [0m
 [0;36m*---\-|-/---* [0;37m| |_| '__| | | \___ \| __|[0m
 [0;36m \  / \|/ \ / [0;37m|  _| |  | |_| |___) | |_ [0m
 [0;36m  \/   *   \/ [0;37m|_| |_|   \___/|____/ \__|[0m
 [0;36m  /\  /|\  /\ [0m
 [0;36m /  \/ | \/  \[0;31m  ───────────────────────────[0m
 [0;36m*---/-|-\---* [0;37m  Frozen Operating System v1.0[0m
 [0;36m \  /  |  \ / [0;36m  Overlay: [0;32mACTIVE[0;36m  Persist: [0;32mON[0m
 [0;36m  --\  |  /-- [0m
 [0;36m     \ | /    [0;90m  All changes are transient unless[0m
 [0;36m      \|/     [0;90m  you persist them explicitly.[0m
 [0;36m       *      [0m

 [1;36m Quick commands:[0m
   [0;36mfrost-persist list[0m       [0;90m- See what's persistent[0m
   [0;36mfrost-persist add <path>[0m [0;90m- Make a path persistent[0m
   [0;36mfrost-config wizard[0m      [0;90m- Run setup wizard[0m
   [0;36mfrost-overlay status[0m     [0;90m- Check overlay status[0m

MOTD

    # Set up locale
    chroot "${ROOTFS_DIR}" bash -c "
        echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen
        locale-gen 2>/dev/null || true
    "

    # Create frost config directory
    mkdir -p "${ROOTFS_DIR}/etc/frost"

    # Create systemd service for frost persistence sync
    cat > "${ROOTFS_DIR}/etc/systemd/system/frost-sync.service" << 'SERVICE'
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
SERVICE

    # Enable the service
    chroot "${ROOTFS_DIR}" bash -c "
        systemctl enable frost-sync.service 2>/dev/null || true
    "

    # Clean up apt cache in rootfs (will be in squashfs, save space)
    chroot "${ROOTFS_DIR}" bash -c "
        apt-get clean
        rm -rf /var/cache/apt/archives/*.deb
        rm -rf /tmp/*
        rm -rf /var/tmp/*
    "

    ok "Rootfs configured"
}

# =============================================================================
# Install frOSt tools into rootfs
# =============================================================================
install_frost_tools() {
    log "Installing frOSt tools..."

    local bindir="${ROOTFS_DIR}/usr/local/bin"
    mkdir -p "${bindir}"

    # Copy Python tools
    cp "${SRC_DIR}/tools/frost-persist.py" "${bindir}/frost-persist"
    cp "${SRC_DIR}/tools/frost-overlay.py" "${bindir}/frost-overlay"
    cp "${SRC_DIR}/tools/frost-config.py"  "${bindir}/frost-config"

    chmod 755 "${bindir}/frost-persist"
    chmod 755 "${bindir}/frost-overlay"
    chmod 755 "${bindir}/frost-config"

    # Add shebang if missing
    for tool in frost-persist frost-overlay frost-config; do
        if ! head -1 "${bindir}/${tool}" | grep -q '^#!'; then
            sed -i '1i#!/usr/bin/env python3' "${bindir}/${tool}"
        fi
    done

    ok "frOSt tools installed"
}

# =============================================================================
# Install desktop environment and apply frOSt theme
# =============================================================================
install_desktop() {
    log "Configuring desktop environment..."

    # Mount essential filesystems for chroot operations
    mount --bind /dev "${ROOTFS_DIR}/dev" 2>/dev/null || true
    mount --bind /dev/pts "${ROOTFS_DIR}/dev/pts" 2>/dev/null || true
    mount -t proc proc "${ROOTFS_DIR}/proc" 2>/dev/null || true
    mount -t sysfs sysfs "${ROOTFS_DIR}/sys" 2>/dev/null || true
    mount -t tmpfs tmpfs "${ROOTFS_DIR}/tmp" 2>/dev/null || true

    # Enable LightDM as display manager
    chroot "${ROOTFS_DIR}" bash -c "
        systemctl enable lightdm 2>/dev/null || true
    "

    # ---- Apply frOSt theme ----
    log "Applying frOSt desktop theme..."

    # Create wallpaper directory and convert SVG to PNG
    mkdir -p "${ROOTFS_DIR}/usr/share/backgrounds/frost"
    cp "${SRC_DIR}/desktop/wallpaper.svg" "${ROOTFS_DIR}/usr/share/backgrounds/frost/"
    cp "${SRC_DIR}/desktop/frost-logo.svg" "${ROOTFS_DIR}/usr/share/backgrounds/frost/"

    # Convert SVGs to PNG using rsvg-convert in chroot
    chroot "${ROOTFS_DIR}" bash -c "
        if command -v rsvg-convert >/dev/null 2>&1; then
            rsvg-convert -w 1920 -h 1080 /usr/share/backgrounds/frost/wallpaper.svg \
                -o /usr/share/backgrounds/frost/wallpaper.png
            rsvg-convert -w 128 -h 128 /usr/share/backgrounds/frost/frost-logo.svg \
                -o /usr/share/backgrounds/frost/frost-logo.png
        else
            echo 'WARNING: rsvg-convert not found, SVG wallpapers only'
        fi
    "

    # Install LightDM configuration
    cp "${SRC_DIR}/desktop/lightdm/lightdm.conf" \
        "${ROOTFS_DIR}/etc/lightdm/lightdm.conf"
    cp "${SRC_DIR}/desktop/lightdm/lightdm-gtk-greeter.conf" \
        "${ROOTFS_DIR}/etc/lightdm/lightdm-gtk-greeter.conf"

    # Install XFCE4 default configs (system-wide defaults)
    local xdg_xfce="${ROOTFS_DIR}/etc/xdg/xfce4"
    mkdir -p "${xdg_xfce}/xfconf/xfce-perchannel-xml"
    mkdir -p "${xdg_xfce}/terminal"
    cp "${SRC_DIR}/desktop/xfce4/xfconf/xfce-perchannel-xml/"*.xml \
        "${xdg_xfce}/xfconf/xfce-perchannel-xml/"
    cp "${SRC_DIR}/desktop/xfce4/terminal/terminalrc" \
        "${xdg_xfce}/terminal/"

    # Also copy to frost user home for immediate use
    local user_xfce="${ROOTFS_DIR}/home/frost/.config/xfce4"
    mkdir -p "${user_xfce}/xfconf/xfce-perchannel-xml"
    mkdir -p "${user_xfce}/terminal"
    cp "${SRC_DIR}/desktop/xfce4/xfconf/xfce-perchannel-xml/"*.xml \
        "${user_xfce}/xfconf/xfce-perchannel-xml/"
    cp "${SRC_DIR}/desktop/xfce4/terminal/terminalrc" \
        "${user_xfce}/terminal/"

    # Install GTK3 theme overlay
    local user_gtk="${ROOTFS_DIR}/home/frost/.config/gtk-3.0"
    local sys_gtk="${ROOTFS_DIR}/etc/gtk-3.0"
    mkdir -p "${user_gtk}" "${sys_gtk}"
    cp "${SRC_DIR}/desktop/gtk-3.0/gtk.css" "${user_gtk}/"
    cp "${SRC_DIR}/desktop/gtk-3.0/gtk.css" "${sys_gtk}/"

    # Install Conky config
    mkdir -p "${ROOTFS_DIR}/etc/frost"
    cp "${SRC_DIR}/desktop/conky/conky.conf" "${ROOTFS_DIR}/etc/frost/"

    # Install Conky autostart
    local user_autostart="${ROOTFS_DIR}/home/frost/.config/autostart"
    local sys_autostart="${ROOTFS_DIR}/etc/xdg/autostart"
    mkdir -p "${user_autostart}" "${sys_autostart}"
    cp "${SRC_DIR}/desktop/autostart/conky.desktop" "${user_autostart}/"
    cp "${SRC_DIR}/desktop/autostart/conky.desktop" "${sys_autostart}/"

    # Install Neofetch config
    local user_neofetch="${ROOTFS_DIR}/home/frost/.config/neofetch"
    mkdir -p "${user_neofetch}"
    cp "${SRC_DIR}/desktop/neofetch/config.conf" "${ROOTFS_DIR}/etc/frost/neofetch.conf"
    cp "${SRC_DIR}/desktop/neofetch/config.conf" "${user_neofetch}/"
    cp "${SRC_DIR}/desktop/neofetch/frost-ascii" "${user_neofetch}/"

    # Install frost shell prompt
    cp "${SRC_DIR}/desktop/bashrc-frost" "${ROOTFS_DIR}/etc/profile.d/frost-prompt.sh"
    chmod 644 "${ROOTFS_DIR}/etc/profile.d/frost-prompt.sh"

    # Install frost logo as icon for whisker menu
    mkdir -p "${ROOTFS_DIR}/usr/share/icons/hicolor/128x128/apps"
    mkdir -p "${ROOTFS_DIR}/usr/share/icons/hicolor/scalable/apps"
    cp "${SRC_DIR}/desktop/frost-logo.svg" \
        "${ROOTFS_DIR}/usr/share/icons/hicolor/scalable/apps/frost-logo.svg"
    # Copy PNG version if available
    if [ -f "${ROOTFS_DIR}/usr/share/backgrounds/frost/frost-logo.png" ]; then
        cp "${ROOTFS_DIR}/usr/share/backgrounds/frost/frost-logo.png" \
            "${ROOTFS_DIR}/usr/share/icons/hicolor/128x128/apps/frost-logo.png"
    fi

    # Set correct ownership for frost user configs
    chroot "${ROOTFS_DIR}" bash -c "
        chown -R frost:frost /home/frost 2>/dev/null || true
    "

    # Clean up apt cache
    chroot "${ROOTFS_DIR}" bash -c "
        apt-get clean
        rm -rf /var/cache/apt/archives/*.deb /tmp/* /var/tmp/*
    "

    # Unmount chroot filesystems
    umount "${ROOTFS_DIR}/tmp" 2>/dev/null || true
    umount "${ROOTFS_DIR}/sys" 2>/dev/null || true
    umount "${ROOTFS_DIR}/proc" 2>/dev/null || true
    umount "${ROOTFS_DIR}/dev/pts" 2>/dev/null || true
    umount "${ROOTFS_DIR}/dev" 2>/dev/null || true

    ok "Desktop environment installed and themed"
}

# =============================================================================
# Step 2: Assemble x86-64 early init binary
# =============================================================================
build_asm() {
    log "Assembling x86-64 early init stub..."

    local asm_src="${SRC_DIR}/boot/asm/early_init.asm"
    local asm_obj="${BUILD_DIR}/early_init.o"
    local asm_bin="${BUILD_DIR}/early_init"

    [[ -f "${asm_src}" ]] || err "Assembly source not found: ${asm_src}"

    # Assemble
    nasm -f elf64 -o "${asm_obj}" "${asm_src}"

    # Link (static, no libc)
    ld -o "${asm_bin}" "${asm_obj}" --oformat=elf64-x86-64 -e _start --static

    # Verify
    file "${asm_bin}"
    ok "Early init binary built ($(stat -c%s "${asm_bin}") bytes)"
}

# =============================================================================
# Step 3: Build initramfs
# =============================================================================
build_initramfs() {
    log "Building initramfs..."

    rm -rf "${INITRAMFS_DIR}"
    mkdir -p "${INITRAMFS_DIR}"/{bin,sbin,usr/bin,usr/sbin,lib,lib64,dev,proc,sys,etc,run,tmp,frost}

    # Copy busybox (static) for shell and basic utilities
    if command -v busybox >/dev/null 2>&1; then
        cp "$(command -v busybox)" "${INITRAMFS_DIR}/bin/busybox"
    elif [[ -f /bin/busybox ]]; then
        cp /bin/busybox "${INITRAMFS_DIR}/bin/busybox"
    else
        # Install busybox-static
        apt-get install -y -qq busybox-static 2>/dev/null || true
        cp /bin/busybox "${INITRAMFS_DIR}/bin/busybox" 2>/dev/null || \
            err "Cannot find busybox. Install busybox-static."
    fi
    chmod 755 "${INITRAMFS_DIR}/bin/busybox"

    # Create busybox symlinks
    for cmd in sh ash mount umount mkdir cat echo ls cp mv rm ln chmod chown \
               mknod switch_root pivot_root sleep grep sed awk printf \
               mountpoint findfs blkid losetup readlink tr sort touch \
               rmdir basename dirname head tail cut mdev find uname wc; do
        ln -sf busybox "${INITRAMFS_DIR}/bin/${cmd}" 2>/dev/null || true
    done

    # Also link in sbin
    for cmd in modprobe insmod switch_root pivot_root blkid; do
        ln -sf ../bin/busybox "${INITRAMFS_DIR}/sbin/${cmd}" 2>/dev/null || true
    done

    # Copy the early_init binary
    cp "${BUILD_DIR}/early_init" "${INITRAMFS_DIR}/early_init"
    chmod 755 "${INITRAMFS_DIR}/early_init"

    # Copy the init script (pure shell - no Python dependency in initramfs)
    cp "${SRC_DIR}/initramfs/init" "${INITRAMFS_DIR}/init"
    chmod 755 "${INITRAMFS_DIR}/init"

    # Copy frost tools (installed into merged root during pivot)
    cp "${SRC_DIR}/tools/frost-persist.py" "${INITRAMFS_DIR}/frost-persist.py"
    cp "${SRC_DIR}/tools/frost-overlay.py" "${INITRAMFS_DIR}/frost-overlay.py"
    cp "${SRC_DIR}/tools/frost-config.py"  "${INITRAMFS_DIR}/frost-config.py"

    # Create device nodes
    mknod -m 622 "${INITRAMFS_DIR}/dev/console" c 5 1 2>/dev/null || true
    mknod -m 666 "${INITRAMFS_DIR}/dev/null"    c 1 3 2>/dev/null || true
    mknod -m 666 "${INITRAMFS_DIR}/dev/zero"    c 1 5 2>/dev/null || true
    mknod -m 666 "${INITRAMFS_DIR}/dev/tty"     c 5 0 2>/dev/null || true

    # Copy kernel modules needed for overlay and USB
    copy_kernel_modules

    # Create the initramfs cpio archive
    log "Creating initramfs cpio archive..."
    cd "${INITRAMFS_DIR}"
    find . | cpio -o -H newc 2>/dev/null | gzip -9 > "${BUILD_DIR}/initramfs.cpio.gz"

    ok "Initramfs built ($(stat -c%s "${BUILD_DIR}/initramfs.cpio.gz") bytes)"
}

# =============================================================================
# Copy essential kernel modules (comprehensive - includes all dependencies)
# =============================================================================
copy_kernel_modules() {
    log "Copying kernel modules..."

    # Find kernel version
    local kver
    kver=$(ls "${ROOTFS_DIR}/lib/modules/" | head -1)

    if [[ -z "${kver}" ]]; then
        warn "No kernel modules found, skipping"
        return
    fi

    local mod_src="${ROOTFS_DIR}/lib/modules/${kver}"
    local mod_dst="${INITRAMFS_DIR}/lib/modules/${kver}"
    mkdir -p "${mod_dst}"

    # Copy entire driver subsystem directories (ensures all dependencies are met)
    for subdir in drivers/ata drivers/scsi drivers/virtio drivers/block \
                  drivers/usb/storage drivers/usb/host drivers/usb/core \
                  drivers/hid \
                  drivers/gpu/drm/bochs drivers/gpu/drm/virtio \
                  drivers/gpu/drm/simpledrm drivers/gpu/drm/tiny \
                  fs/overlayfs fs/squashfs fs/ext4 fs/fat fs/nls fs/jbd2 \
                  block lib crypto arch/x86/crypto; do
        local src_path="${mod_src}/kernel/${subdir}"
        if [[ -d "$src_path" ]]; then
            local dst_path="${mod_dst}/kernel/${subdir}"
            mkdir -p "$dst_path"
            cp -r "${src_path}"/* "$dst_path/" 2>/dev/null || true
        fi
    done

    # Also copy key individual modules (in case they're outside the above dirs)
    for mod_pattern in "overlay.ko*" "squashfs.ko*" "loop.ko*" "virtio*.ko*" \
                       "libata.ko*" "ata_piix.ko*" "ahci.ko*" "sd_mod.ko*" \
                       "scsi_mod.ko*" "ata_generic.ko*" "libahci.ko*" \
                       "mbcache.ko*" "jbd2.ko*" "ext4.ko*" "crc*.ko*" \
                       "t10-pi.ko*" "crct10dif*.ko*" "crc-t10dif.ko*" \
                       "crc32c_generic.ko*" "crc64_rocksoft.ko*" \
                       "usb-common.ko*" "usbcore.ko*" "usb-storage.ko*" \
                       "xhci*.ko*" "ehci*.ko*" \
                       "hid.ko*" "usbhid.ko*" "hid-generic.ko*" \
                       "nls_*.ko*" "fat.ko*" "vfat.ko*" \
                       "drm.ko*" "drm_kms_helper.ko*" "bochs*.ko*" \
                       "virtio-gpu.ko*" "simpledrm.ko*"; do
        find "${mod_src}" -name "${mod_pattern}" 2>/dev/null | while read mod_file; do
            local rel_path="${mod_file#${mod_src}/}"
            local dest_dir="${mod_dst}/$(dirname "$rel_path")"
            mkdir -p "$dest_dir"
            cp "$mod_file" "$dest_dir/" 2>/dev/null || true
        done
    done

    # Copy modules.dep and related metadata files
    cp "${mod_src}/modules."* "${mod_dst}/" 2>/dev/null || true

    # Regenerate modules.dep for our subset
    depmod -b "${INITRAMFS_DIR}" "${kver}" 2>/dev/null || true

    local mod_count
    mod_count=$(find "${mod_dst}" -name '*.ko*' 2>/dev/null | wc -l)
    ok "Kernel modules copied for ${kver} (${mod_count} modules)"
}

# =============================================================================
# Step 4: Create the disk image
# =============================================================================
build_image() {
    log "Creating disk image (${IMAGE_SIZE_MB}MB)..."

    # Create sparse image file
    dd if=/dev/zero of="${IMAGE_FILE}" bs=1M count=0 seek="${IMAGE_SIZE_MB}" 2>/dev/null

    # Partition the image
    # Partition 1: EFI System Partition (FAT32)
    # Partition 2: Root filesystem (squashfs)
    # Partition 3: Persistence (ext4)
    parted -s "${IMAGE_FILE}" \
        mklabel gpt \
        mkpart "EFI" fat32 1MiB ${EFI_SIZE_MB}MiB \
        set 1 esp on \
        mkpart "FROST_ROOT" ext4 ${EFI_SIZE_MB}MiB $((EFI_SIZE_MB + ROOT_SIZE_MB))MiB \
        mkpart "FROST_PERSIST" ext4 $((EFI_SIZE_MB + ROOT_SIZE_MB))MiB 100%

    ok "Partition table created"

    # Set up loop device
    local loop_dev
    loop_dev=$(losetup --show -fP "${IMAGE_FILE}")
    log "Loop device: ${loop_dev}"

    # Wait for partition devices to appear
    sleep 1
    partprobe "${loop_dev}" 2>/dev/null || true
    sleep 1

    # Format partitions
    log "Formatting partitions..."
    mkfs.fat -F32 -n "EFI" "${loop_dev}p1"
    mkfs.ext4 -L "FROST_ROOT" -q "${loop_dev}p2"
    mkfs.ext4 -L "FROST_PERSIST" -q "${loop_dev}p3"

    # Mount and populate partitions
    local mnt="${BUILD_DIR}/mnt"
    mkdir -p "${mnt}"/{efi,root,persist}

    # === EFI Partition ===
    mount "${loop_dev}p1" "${mnt}/efi"
    populate_efi "${mnt}/efi" "${loop_dev}"

    # === Root Partition ===
    mount "${loop_dev}p2" "${mnt}/root"
    populate_root "${mnt}/root"

    # === Persistence Partition ===
    mount "${loop_dev}p3" "${mnt}/persist"
    populate_persist "${mnt}/persist"

    # Unmount everything
    sync
    umount "${mnt}/persist"
    umount "${mnt}/root"
    umount "${mnt}/efi"

    # Detach loop device
    losetup -d "${loop_dev}"

    ok "Disk image created: ${IMAGE_FILE} ($(du -h "${IMAGE_FILE}" | cut -f1))"
}

# =============================================================================
# Populate EFI partition
# =============================================================================
populate_efi() {
    local efi_dir="$1"
    local loop_dev="$2"

    log "Populating EFI partition..."

    # Find kernel and initramfs
    local kver
    kver=$(ls "${ROOTFS_DIR}/lib/modules/" | head -1)

    local vmlinuz="${ROOTFS_DIR}/boot/vmlinuz-${kver}"
    if [[ ! -f "${vmlinuz}" ]]; then
        vmlinuz=$(find "${ROOTFS_DIR}/boot" -name 'vmlinuz-*' | head -1)
    fi
    [[ -f "${vmlinuz}" ]] || err "Kernel not found"

    # Create directory structure
    mkdir -p "${efi_dir}/EFI/BOOT"
    mkdir -p "${efi_dir}/boot/grub"

    # Copy kernel
    cp "${vmlinuz}" "${efi_dir}/boot/vmlinuz"

    # Copy our custom initramfs
    cp "${BUILD_DIR}/initramfs.cpio.gz" "${efi_dir}/boot/initramfs.img"

    # Install GRUB for EFI
    grub-mkimage \
        -o "${efi_dir}/EFI/BOOT/BOOTX64.EFI" \
        -O x86_64-efi \
        -p /boot/grub \
        part_gpt part_msdos fat ext2 normal boot linux \
        configfile loopback chain efifwsetup efi_gop \
        efi_uga ls search search_label search_fs_uuid \
        search_fs_file gfxterm gfxterm_background \
        gfxterm_menu test all_video loadenv echo

    # Install GRUB for BIOS too (hybrid boot)
    if command -v grub-install >/dev/null 2>&1; then
        grub-install \
            --target=i386-pc \
            --boot-directory="${efi_dir}/boot" \
            --modules="part_gpt part_msdos fat ext2 normal boot linux configfile search search_label" \
            "${loop_dev}" 2>/dev/null || warn "BIOS GRUB install failed (EFI only)"
    fi

    # Write GRUB config
    cat > "${efi_dir}/boot/grub/grub.cfg" << 'GRUBCFG'
set timeout=3
set default=0

serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1
terminal_input serial console
terminal_output serial console

# frOSt color scheme - icy cyan on dark
set color_normal=cyan/black
set color_highlight=white/blue
set menu_color_normal=cyan/black
set menu_color_highlight=white/blue

echo ""
echo "  ╔═══════════════════════════════════════╗"
echo "  ║   frOSt - Frozen Operating System     ║"
echo "  ║   Overlay Filesystem + Persistence    ║"
echo "  ╚═══════════════════════════════════════╝"
echo ""

menuentry "frOSt Desktop" {
    linux /boot/vmlinuz root=LABEL=FROST_ROOT ro quiet splash console=tty0 console=ttyS0,115200
    initrd /boot/initramfs.img
}

menuentry "frOSt Console (Text Mode)" {
    linux /boot/vmlinuz root=LABEL=FROST_ROOT ro quiet console=tty0 console=ttyS0,115200 systemd.unit=multi-user.target
    initrd /boot/initramfs.img
}

menuentry "frOSt (Recovery Mode)" {
    linux /boot/vmlinuz root=LABEL=FROST_ROOT ro single console=tty0 console=ttyS0,115200
    initrd /boot/initramfs.img
}

menuentry "frOSt (Debug - Verbose Boot)" {
    linux /boot/vmlinuz root=LABEL=FROST_ROOT ro debug loglevel=7 console=tty0 console=ttyS0,115200
    initrd /boot/initramfs.img
}
GRUBCFG

    ok "EFI partition populated"
}

# =============================================================================
# Populate root partition (squashfs or direct copy)
# =============================================================================
populate_root() {
    local root_dir="$1"

    log "Populating root partition..."

    # Try to create squashfs
    if command -v mksquashfs >/dev/null 2>&1; then
        log "Creating squashfs image..."
        mksquashfs "${ROOTFS_DIR}" "${root_dir}/rootfs.squashfs" \
            -comp xz -no-xattrs -quiet 2>/dev/null || \
        mksquashfs "${ROOTFS_DIR}" "${root_dir}/rootfs.squashfs" \
            -comp gzip -no-xattrs -quiet

        ok "Squashfs created ($(du -h "${root_dir}/rootfs.squashfs" | cut -f1))"
    else
        # Fallback: copy rootfs directly
        log "Squashfs unavailable, copying rootfs directly..."
        cp -a "${ROOTFS_DIR}"/* "${root_dir}/"
        ok "Rootfs copied directly"
    fi
}

# =============================================================================
# Populate persistence partition with default config
# =============================================================================
populate_persist() {
    local persist_dir="$1"

    log "Setting up persistence partition..."

    mkdir -p "${persist_dir}/data"

    # Write default persistence config
    cat > "${persist_dir}/frost-persist.json" << 'PERSISTCFG'
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
PERSISTCFG

    ok "Persistence partition initialized"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo -e "${CYAN}"
    echo '  __       ___  ____  _   '
    echo ' / _|_ __ / _ \/ ___|| |_ '
    echo '| |_| |__| | | \___ \| __|'
    echo '|  _| |  | |_| |___) | |_ '
    echo '|_| |_|   \___/|____/ \__|'
    echo -e "${RESET}"
    echo "frOSt Build System v${FROST_VERSION}"
    echo "================================="
    echo ""

    # Clean previous build
    rm -rf "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}"

    preflight
    build_rootfs
    install_desktop
    build_asm
    build_initramfs
    build_image

    echo ""
    echo -e "${GREEN}============================================="
    echo " frOSt build complete!"
    echo " Image: ${IMAGE_FILE}"
    echo " Size:  $(du -h "${IMAGE_FILE}" | cut -f1)"
    echo ""
    echo " To test with QEMU:"
    echo "   bash test.sh desktop    # Desktop mode (recommended)"
    echo "   bash test.sh bios       # BIOS text mode"
    echo "   bash test.sh uefi       # UEFI mode"
    echo "=============================================${RESET}"
}

# Run main
main "$@"
