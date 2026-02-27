#!/bin/bash
# =============================================================================
# Rebuild frOSt image from cached rootfs
# =============================================================================
# Uses the cached rootfs at /root/frost-build/rootfs to:
#   1. Build fresh squashfs
#   2. Write it to FROST_ROOT partition
#   3. Rebuild initramfs with latest init scripts
# =============================================================================
set -e

SRC=/mnt/c/Users/thoma/Documents/frOSt
IMG=/mnt/c/Users/thoma/Documents/frOSt/frost.img
BUILD=/root/frost-build
ROOTFS="${BUILD}/rootfs"

CYAN='\033[1;36m'
GREEN='\033[1;32m'
RED='\033[1;31m'
RESET='\033[0m'

log() { echo -e "${CYAN}[rebuild]${RESET} $1"; }
ok()  { echo -e "${GREEN}[rebuild]${RESET} $1"; }
err() { echo -e "${RED}[rebuild] ERROR:${RESET} $1"; exit 1; }

# Verify cached rootfs exists
[ -d "${ROOTFS}/sbin" ] || err "No cached rootfs at ${ROOTFS}"
[ -f "${ROOTFS}/sbin/init" ] || [ -L "${ROOTFS}/sbin/init" ] || err "No /sbin/init in rootfs"
ok "Cached rootfs found: $(du -sh ${ROOTFS} | cut -f1)"

# Setup loop device
losetup -D 2>/dev/null || true
sleep 1
losetup -fP "$IMG"
sleep 1
LOOP=$(losetup -j "$IMG" | head -1 | cut -d: -f1)
[ -n "$LOOP" ] || err "Failed to set up loop device"
log "Loop: $LOOP"

cleanup() {
    log "Cleaning up..."
    umount /tmp/frost-efi 2>/dev/null || true
    umount /tmp/frost-root 2>/dev/null || true
    [ -n "${LOOP:-}" ] && losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

# =============================================================================
# Phase 1: Rebuild squashfs and write to FROST_ROOT
# =============================================================================
log "=== Phase 1: Rebuilding squashfs ==="

mkdir -p /tmp/frost-root /tmp/frost-efi

# Mount root partition
mount "${LOOP}p2" /tmp/frost-root
log "FROST_ROOT mounted, current contents:"
ls -la /tmp/frost-root/

# Build squashfs from cached rootfs
log "Building squashfs from cached rootfs (this may take a while)..."
rm -f /tmp/frost-root/rootfs.squashfs

mksquashfs "${ROOTFS}" /tmp/frost-root/rootfs.squashfs \
    -comp xz -Xbcj x86 -b 256K -no-exports -noappend \
    -e boot/vmlinuz-* boot/initrd.img-* boot/initramfs* 2>&1 | tail -5

ok "Squashfs written: $(du -h /tmp/frost-root/rootfs.squashfs | cut -f1)"

# Verify
ls -lh /tmp/frost-root/rootfs.squashfs
file /tmp/frost-root/rootfs.squashfs

# Quick check - mount squashfs and verify Python/init
mkdir -p /tmp/frost-sqfs-check
mount -t squashfs -o ro,loop /tmp/frost-root/rootfs.squashfs /tmp/frost-sqfs-check
log "Squashfs contents check:"
echo "  /sbin/init: $(ls -la /tmp/frost-sqfs-check/sbin/init 2>/dev/null || echo 'NOT FOUND')"
echo "  systemd: $(ls -la /tmp/frost-sqfs-check/lib/systemd/systemd 2>/dev/null || echo 'NOT FOUND')"
echo "  python3: $(ls -la /tmp/frost-sqfs-check/usr/bin/python3 2>/dev/null || echo 'NOT FOUND')"
echo "  ld-linux: $(ls /tmp/frost-sqfs-check/lib64/ld-linux-x86-64.so.2 /tmp/frost-sqfs-check/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 2>/dev/null | head -1 || echo 'NOT FOUND')"
umount /tmp/frost-sqfs-check

umount /tmp/frost-root

# =============================================================================
# Phase 2: Rebuild initramfs
# =============================================================================
log "=== Phase 2: Rebuilding initramfs ==="

mount "${LOOP}p1" /tmp/frost-efi

# Extract existing initramfs
INITDIR=/tmp/frost-initramfs
rm -rf "$INITDIR"
mkdir -p "$INITDIR"
cd "$INITDIR"
gzip -dc /tmp/frost-efi/boot/initramfs.img | cpio -id 2>/dev/null
ok "Existing initramfs extracted"

# Rebuild assembly early_init
if command -v nasm >/dev/null 2>&1; then
    nasm -f elf64 -o /tmp/early_init.o "${SRC}/boot/asm/early_init.asm"
    ld -o "${INITDIR}/early_init" /tmp/early_init.o --oformat=elf64-x86-64 -e _start --static
    strip --strip-all "${INITDIR}/early_init" 2>/dev/null || true
    chmod 755 "${INITDIR}/early_init"
    ok "Assembly early_init rebuilt"
fi

# Update init scripts
cp "${SRC}/initramfs/init" "${INITDIR}/init"
chmod 755 "${INITDIR}/init"
cp "${SRC}/initramfs/frost_init.py" "${INITDIR}/frost_init.py"
chmod 755 "${INITDIR}/frost_init.py"
ok "Init scripts updated"

# Update tools
for tool in frost-persist.py frost-overlay.py frost-config.py; do
    [ -f "${SRC}/tools/${tool}" ] && cp "${SRC}/tools/${tool}" "${INITDIR}/${tool}"
done

# Repack
cd "$INITDIR"
find . | cpio -o -H newc 2>/dev/null | gzip -9 > /tmp/initramfs.cpio.gz
cp /tmp/initramfs.cpio.gz /tmp/frost-efi/boot/initramfs.img
ok "Initramfs: $(du -h /tmp/frost-efi/boot/initramfs.img | cut -f1)"

sync
umount /tmp/frost-efi

echo ""
ok "=== Image rebuild complete ==="
echo ""
log "FROST_ROOT now has rootfs.squashfs"
log "Initramfs updated with latest init scripts"
log "Ready for QEMU test"
