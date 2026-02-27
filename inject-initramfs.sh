#!/bin/bash
# Quick inject: mount EFI partition and replace initramfs
set -e
IMG=/mnt/c/Users/thoma/Documents/frOSt/frost.img
BUILD=/root/frost-pyinit-build

# Clean up any stale loops
losetup -D 2>/dev/null || true

# Fresh loop attach
losetup -fP "${IMG}"
sleep 1
LOOP=$(losetup -j "${IMG}" | head -1 | cut -d: -f1)
echo "Loop: ${LOOP}"
ls ${LOOP}* 2>/dev/null

# Wait for partition nodes
sleep 2
partprobe "${LOOP}" 2>/dev/null || true
sleep 1

if [ ! -b "${LOOP}p1" ]; then
    echo "ERROR: ${LOOP}p1 not found"
    losetup -l
    exit 1
fi

mkdir -p "${BUILD}/efi"
mount "${LOOP}p1" "${BUILD}/efi"

echo "Before:"
ls -lh "${BUILD}/efi/boot/initramfs.img"

cp "${BUILD}/initramfs.cpio.gz" "${BUILD}/efi/boot/initramfs.img"

echo "After:"
ls -lh "${BUILD}/efi/boot/initramfs.img"

sync
umount "${BUILD}/efi"
losetup -d "${LOOP}"

echo "Done - initramfs injected!"
