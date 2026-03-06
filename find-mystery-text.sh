#!/bin/bash
# Find where "Starting initramfs init" and "Early Init v1.0" text lives
set -e

IMG=/mnt/c/Users/thoma/Documents/frOSt/frost.img

echo "=== Searching in first EFI partition (kernel area) ==="
losetup -D 2>/dev/null || true
losetup -fP "$IMG"
sleep 2
LOOP=$(losetup -j "$IMG" | head -1 | cut -d: -f1)
partprobe "$LOOP" 2>/dev/null || true
sleep 1

# Check the kernel binary
mkdir -p /tmp/fkc
mount "${LOOP}p1" /tmp/fkc
echo "--- Kernel strings ---"
strings /tmp/fkc/boot/vmlinuz 2>/dev/null | grep -i "Starting initramfs\|Early Init v1\|__       ___" | head -10 || echo "Not in kernel"

echo ""
echo "--- Initramfs contains (search in compressed) ---"
strings /tmp/fkc/boot/initramfs.img 2>/dev/null | grep -i "Starting initramfs\|Early Init v1\|__       ___" | head -10 || echo "Not in compressed initramfs"

echo ""
echo "--- Uncompressed initramfs ---"
cd /tmp
gunzip -c /tmp/fkc/boot/initramfs.img > /tmp/initramfs-raw.cpio 2>/dev/null || cp /tmp/fkc/boot/initramfs.img /tmp/initramfs-raw.cpio
strings /tmp/initramfs-raw.cpio | grep -i "Starting initramfs\|Early Init v1\|__       ___" | head -10 || echo "Not in initramfs data"

# Check in squashfs rootfs  
echo ""
echo "=== Check in squashfs rootfs (partition 2) ==="
mkdir -p /tmp/fp2 /tmp/fsqfs
mount "${LOOP}p2" /tmp/fp2
mount -t squashfs -o ro,loop /tmp/fp2/rootfs.squashfs /tmp/fsqfs 2>/dev/null || true

# Look for init-related files in rootfs
echo "--- Search rootfs for the text ---"
grep -rn "Starting initramfs\|Early Init v1\|__       ___" /tmp/fsqfs/etc/init.d/ /tmp/fsqfs/usr/lib/systemd/ /tmp/fsqfs/usr/local/bin/ 2>/dev/null | head -10 || echo "Not in rootfs scripts"

echo "--- Search for old early_init in rootfs ---"
find /tmp/fsqfs -name "early_init" -type f 2>/dev/null | head -5

echo "--- Any init scripts mentioning frost ---"
find /tmp/fsqfs -name "*frost*" -type f 2>/dev/null | head -20

umount /tmp/fsqfs 2>/dev/null || true
umount /tmp/fp2 2>/dev/null || true
umount /tmp/fkc 2>/dev/null || true
losetup -D

echo "=== DONE ==="
