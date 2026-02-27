#!/bin/bash
# =============================================================================
# frOSt Quick Rebuild - Rebuild init system + apply branding to existing image
# =============================================================================
# Does NOT rebuild the full rootfs (debootstrap). Instead:
#   1. Rebuilds the initramfs (asm early_init + shell init + Python frost_init)
#   2. Updates the squashfs rootfs (MOTD, os-release, WiFi config, services)
# Run as root in WSL Ubuntu.
set -e

IMG=/mnt/c/Users/thoma/Documents/frOSt/frost.img
SRC=/mnt/c/Users/thoma/Documents/frOSt
WORKDIR=/tmp/frost-rebuild
SQFS_MNT="${WORKDIR}/sqfs"
ROOT_MNT="${WORKDIR}/root"
EFI_MNT="${WORKDIR}/efi"
NEW_ROOTFS="${WORKDIR}/new-rootfs"
INITRAMFS="${WORKDIR}/initramfs"

CYAN='\033[1;36m'
GREEN='\033[1;32m'
RED='\033[1;31m'
RESET='\033[0m'

log() { echo -e "${CYAN}[rebuild]${RESET} $1"; }
ok()  { echo -e "${GREEN}[rebuild]${RESET} $1"; }
err() { echo -e "${RED}[rebuild] ERROR:${RESET} $1"; exit 1; }

cleanup() {
    log "Cleaning up..."
    umount "${SQFS_MNT}" 2>/dev/null || true
    umount "${ROOT_MNT}" 2>/dev/null || true
    umount "${EFI_MNT}" 2>/dev/null || true
    LOOP=$(losetup -j "${IMG}" 2>/dev/null | head -1 | cut -d: -f1)
    [ -n "${LOOP}" ] && losetup -d "${LOOP}" 2>/dev/null || true
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

log "Setting up loop device..."
losetup -D 2>/dev/null || true
losetup -fP "${IMG}"
LOOP=$(losetup -j "${IMG}" | head -1 | cut -d: -f1)
[ -n "${LOOP}" ] || err "Failed to set up loop device"
log "Loop: ${LOOP}"

mkdir -p "${ROOT_MNT}" "${EFI_MNT}" "${SQFS_MNT}" "${NEW_ROOTFS}" "${INITRAMFS}"

mount "${LOOP}p1" "${EFI_MNT}"
mount "${LOOP}p2" "${ROOT_MNT}"
mount -t squashfs -o ro,loop "${ROOT_MNT}/rootfs.squashfs" "${SQFS_MNT}"

# =============================================================================
# Phase 1: Rebuild initramfs
# =============================================================================
log "=== Phase 1: Rebuilding initramfs ==="

log "Extracting existing initramfs..."
cd "${INITRAMFS}"
gzip -dc "${EFI_MNT}/boot/initramfs.img" | cpio -id 2>/dev/null
ok "Existing initramfs extracted"

# Update assembly early_init
log "Rebuilding assembly early_init..."
if command -v nasm >/dev/null 2>&1; then
    nasm -f elf64 -o "${WORKDIR}/early_init.o" "${SRC}/boot/asm/early_init.asm"
    ld -o "${INITRAMFS}/early_init" "${WORKDIR}/early_init.o" --oformat=elf64-x86-64 -e _start --static
    strip --strip-all "${INITRAMFS}/early_init" 2>/dev/null || true
    chmod 755 "${INITRAMFS}/early_init"
    ok "Assembly early_init rebuilt ($(stat -c%s "${INITRAMFS}/early_init") bytes)"
else
    log "NASM not available, keeping existing early_init"
fi

# Update init script
log "Updating init script..."
cp "${SRC}/initramfs/init" "${INITRAMFS}/init"
chmod 755 "${INITRAMFS}/init"
ok "Shell init bootstrap updated"

# Update Python init
log "Updating frost_init.py..."
cp "${SRC}/initramfs/frost_init.py" "${INITRAMFS}/frost_init.py"
chmod 755 "${INITRAMFS}/frost_init.py"
ok "Python init updated"

# Update tools
for tool in frost-persist.py frost-overlay.py frost-config.py; do
    [ -f "${SRC}/tools/${tool}" ] && cp "${SRC}/tools/${tool}" "${INITRAMFS}/${tool}"
done

# Repack initramfs
log "Packing initramfs..."
cd "${INITRAMFS}"
find . | cpio -o -H newc 2>/dev/null | gzip -9 > "${WORKDIR}/initramfs.cpio.gz"
cp "${WORKDIR}/initramfs.cpio.gz" "${EFI_MNT}/boot/initramfs.img"
ok "Initramfs: $(du -h "${EFI_MNT}/boot/initramfs.img" | cut -f1)"

# =============================================================================
# Phase 2: Update squashfs rootfs
# =============================================================================
log "=== Phase 2: Updating squashfs ==="

log "Creating writable rootfs copy..."
cp -a "${SQFS_MNT}/." "${NEW_ROOTFS}/"
umount "${SQFS_MNT}"
ok "Rootfs copied"

# Update MOTD
log "Updating MOTD..."
cat > "${NEW_ROOTFS}/etc/motd" << 'MOTDEOF'

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

MOTDEOF

# Update os-release
log "Updating os-release..."
cat > "${NEW_ROOTFS}/etc/os-release" << 'OSEOF'
PRETTY_NAME="frOSt 3.0.0 (Frozen Operating System)"
NAME="frOSt"
VERSION_ID="3.0.0"
VERSION="3.0.0"
ID=frost
ID_LIKE=debian
HOME_URL="https://github.com/frost-os"
BUG_REPORT_URL="https://github.com/frost-os/issues"
VARIANT="Desktop"
VARIANT_ID=desktop
OSEOF

# Update iwlwifi config
log "Updating WiFi config..."
echo "options iwlmvm power_scheme=1" > "${NEW_ROOTFS}/etc/modprobe.d/iwlwifi.conf"

# Ensure services are enabled
log "Ensuring services enabled..."
WD="${NEW_ROOTFS}/etc/systemd/system/multi-user.target.wants"
mkdir -p "${WD}"
for svc in NetworkManager.service wpa_supplicant.service; do
    [ ! -e "${WD}/${svc}" ] && ln -sf "/lib/systemd/system/${svc}" "${WD}/${svc}" 2>/dev/null || true
done

# Rebuild squashfs
log "Rebuilding squashfs..."
rm -f "${ROOT_MNT}/rootfs.squashfs"
mksquashfs "${NEW_ROOTFS}" "${ROOT_MNT}/rootfs.squashfs" \
    -comp xz -Xbcj x86 -b 256K -no-exports -noappend \
    -e boot/vmlinuz-* boot/initrd.img-* 2>&1 | tail -5
ok "Squashfs: $(du -h "${ROOT_MNT}/rootfs.squashfs" | cut -f1)"

rm -rf "${NEW_ROOTFS}"

echo ""
ok "=== Rebuild complete ==="
echo ""
log "Changes:"
log "  - Assembly early_init: rebuilt with frOSt v3.0 branding"
log "  - Shell init: modules -> devices -> squashfs -> Python handoff"
log "  - Python frost_init: overlayfs + persistence + switch_root"
log "  - MOTD/os-release: updated branding"
log "  - WiFi: enable_ini=0 removed"
log "  - Services: NM + wpa_supplicant ensured enabled"
echo ""
