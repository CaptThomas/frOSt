#!/bin/bash
# Check which early_init is in the current initramfs
set -e

IMG=/mnt/c/Users/thoma/Documents/frOSt/frost.img
WORK=/tmp/frost-check

rm -rf "$WORK"
mkdir -p "$WORK"

# Setup loop device
losetup -D 2>/dev/null || true
losetup -fP "$IMG"
sleep 1
LOOP=$(losetup -j "$IMG" | head -1 | cut -d: -f1)
sleep 1
partprobe "$LOOP" 2>/dev/null || true
sleep 1

# Mount EFI partition and extract initramfs
mkdir -p "$WORK/efi"
mount "${LOOP}p1" "$WORK/efi"
echo "=== Initramfs info ==="
ls -la "$WORK/efi/boot/initramfs.img"
cp "$WORK/efi/boot/initramfs.img" "$WORK/initramfs.cpio.gz"
umount "$WORK/efi"
losetup -D

# Extract initramfs
cd "$WORK"
gunzip -f initramfs.cpio.gz 2>/dev/null || true
mkdir -p extracted
cd extracted
cpio -id < ../initramfs.cpio 2>/dev/null || cpio -id < ../initramfs.cpio.gz 2>/dev/null || true

echo "=== early_init binary ==="
ls -la early_init 2>/dev/null || echo "NO early_init found"

echo "=== Strings in early_init (looking for banner text) ==="
strings early_init 2>/dev/null | grep -iE "frost|init|module|kernel|RAM|loading|banner|asm|overlay|scan|block" | head -40

echo "=== All strings ==="
strings early_init 2>/dev/null | head -60

echo "=== DONE ==="
