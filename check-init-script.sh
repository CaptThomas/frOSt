#!/bin/bash
# Extract and show the init script from the initramfs
set -e

IMG=/mnt/c/Users/thoma/Documents/frOSt/frost.img
WORK=/tmp/frost-init-check

rm -rf "$WORK"
mkdir -p "$WORK"

losetup -D 2>/dev/null || true
losetup -fP "$IMG"
sleep 1
LOOP=$(losetup -j "$IMG" | head -1 | cut -d: -f1)
sleep 1
partprobe "$LOOP" 2>/dev/null || true
sleep 1

mkdir -p "$WORK/efi"
mount "${LOOP}p1" "$WORK/efi"
cp "$WORK/efi/boot/initramfs.img" "$WORK/initramfs.cpio.gz"
umount "$WORK/efi"
losetup -D

cd "$WORK"
gunzip -f initramfs.cpio.gz 2>/dev/null || true
mkdir -p extracted
cd extracted
cpio -id < ../initramfs.cpio 2>/dev/null || cpio -id < ../initramfs.cpio.gz 2>/dev/null || true

echo "=== /init in initramfs (first 80 lines) ==="
head -80 init

echo ""
echo "=== Search for banner/figlet text ==="
grep -n "Starting initramfs\|Early Init\|__       ___\|/ _|_ __\|frOSt.*v1" init || echo "Not found in init"

echo ""
echo "=== MD5 of init in initramfs vs source ==="
echo "Initramfs init: $(md5sum init | awk '{print $1}')"
echo "Source init:    $(md5sum /mnt/c/Users/thoma/Documents/frOSt/initramfs/init | awk '{print $1}')"

echo "=== DONE ==="
