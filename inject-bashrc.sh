#!/bin/bash
# Inject updated bashrc-frost into squashfs inside frost.img
set -euo pipefail

C='\033[1;36m'
G='\033[1;32m'
R='\033[1;31m'
N='\033[0m'

log() { echo -e "${C}[frOSt]${N} $1"; }
ok()  { echo -e "${G}[OK]${N} $1"; }
err() { echo -e "${R}[ERROR]${N} $1"; exit 1; }

SRC=/mnt/c/Users/thoma/Documents/frOSt
IMG=${SRC}/frost.img
BUILD=/root/frost-sqfs-inject

[[ $EUID -eq 0 ]] || err "Must run as root"
[[ -f "${IMG}" ]] || err "frost.img not found"

cleanup() {
    umount ${BUILD}/sqfs 2>/dev/null || true
    umount ${BUILD}/root 2>/dev/null || true
    local l
    l=$(losetup -j "${IMG}" 2>/dev/null | awk -F: 'NR==1{print $1}') || true
    [ -n "$l" ] && losetup -d "$l" 2>/dev/null || true
}
trap cleanup EXIT

rm -rf "${BUILD}"
mkdir -p "${BUILD}"/{root,sqfs,new_root}

log "Mounting image..."
losetup -D 2>/dev/null || true
losetup -fP "${IMG}"
sleep 1
LOOP=$(losetup -j "${IMG}" 2>/dev/null | awk -F: 'NR==1{print $1}') || true
[ -z "$LOOP" ] && err "losetup failed"
sleep 1; partprobe "${LOOP}" 2>/dev/null || true; sleep 1
log "Loop: ${LOOP}"

mount "${LOOP}p2" ${BUILD}/root
mount -t squashfs -o ro,loop ${BUILD}/root/rootfs.squashfs ${BUILD}/sqfs

log "Extracting squashfs (this takes a moment)..."
cp -a ${BUILD}/sqfs/* ${BUILD}/new_root/

log "Injecting updated bashrc-frost..."
cp "${SRC}/desktop/bashrc-frost" "${BUILD}/new_root/etc/profile.d/frost-prompt.sh"
chmod 644 "${BUILD}/new_root/etc/profile.d/frost-prompt.sh"
ok "bashrc-frost injected"

log "Repacking squashfs (xz compression)..."
mksquashfs ${BUILD}/new_root ${BUILD}/rootfs.squashfs -comp xz -b 256K -Xbcj x86 -noappend -quiet
ok "Squashfs: $(du -h ${BUILD}/rootfs.squashfs | cut -f1)"

log "Replacing squashfs in image..."
umount ${BUILD}/sqfs
cp ${BUILD}/rootfs.squashfs ${BUILD}/root/rootfs.squashfs
sync
ok "Image updated"

echo ""
echo -e "${G}═══════════════════════════════════════════${N}"
echo -e "${G} Squashfs updated with new bashrc-frost!${N}"
echo -e "${G}═══════════════════════════════════════════${N}"
