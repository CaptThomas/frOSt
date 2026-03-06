#!/bin/bash
set -e
IMG=/mnt/c/Users/thoma/Documents/frOSt/frost.img
losetup -D 2>/dev/null || true
losetup -fP "$IMG"
sleep 2
LOOP=$(losetup -j "$IMG" | head -1 | cut -d: -f1)
partprobe "$LOOP" 2>/dev/null || true
sleep 1
mkdir -p /tmp/fg
mount "${LOOP}p1" /tmp/fg
echo "=== GRUB CONFIG ==="
cat /tmp/fg/boot/grub/grub.cfg
umount /tmp/fg
losetup -D
