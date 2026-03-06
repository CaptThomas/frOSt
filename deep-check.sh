#!/bin/bash
# Deep verify: extract initramfs and check the ACTUAL strings in the early_init binary
set -e

IMG=/mnt/c/Users/thoma/Documents/frOSt/frost.img
WORK=/tmp/frost-deep-check

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

echo "=== EFI partition contents ==="
ls -la "$WORK/efi/boot/"

# Extract the initramfs
cp "$WORK/efi/boot/initramfs.img" "$WORK/initramfs.cpio.gz"
umount "$WORK/efi"
losetup -D

cd "$WORK"
gunzip -f initramfs.cpio.gz 2>/dev/null || true

echo ""
echo "=== Extracting initramfs ==="
mkdir -p extracted
cd extracted

# Try different extraction methods
cpio -id < ../initramfs.cpio 2>/dev/null && echo "Extracted with cpio -id" || \
    { zcat ../initramfs.cpio.gz 2>/dev/null | cpio -id 2>/dev/null && echo "Extracted with zcat|cpio"; } || \
    echo "Failed to extract"

echo ""
echo "=== Files in initramfs root ==="
ls -la . | head -20

echo ""
echo "=== early_init info ==="
file early_init 2>/dev/null || echo "file command not found"
ls -la early_init
md5sum early_init

echo ""
echo "=== ALL messages in early_init (no grep filter) ==="
strings early_init | cat

echo ""
echo "=== init script first 40 lines ==="
head -40 init

echo "=== DONE ==="
