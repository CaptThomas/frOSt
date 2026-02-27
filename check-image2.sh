#!/bin/bash
# Check EFI partition and persist partition contents
IMG=/mnt/c/Users/thoma/Documents/frOSt/frost.img
LOOP=$(losetup -j "$IMG" | head -1 | cut -d: -f1)
[ -z "$LOOP" ] && { losetup -fP "$IMG"; sleep 1; LOOP=$(losetup -j "$IMG" | head -1 | cut -d: -f1); }

echo "=== EFI partition (p1) ==="
mkdir -p /tmp/frost-efi
mount -o ro ${LOOP}p1 /tmp/frost-efi
find /tmp/frost-efi -type f | head -30
echo ""
echo "=== Kernel ==="
ls -lh /tmp/frost-efi/boot/vmlinuz* 2>/dev/null || echo "No kernel"
echo "=== Initramfs ==="
ls -lh /tmp/frost-efi/boot/initramfs* 2>/dev/null || echo "No initramfs"
echo "=== GRUB config ==="
cat /tmp/frost-efi/boot/grub/grub.cfg 2>/dev/null || echo "No grub.cfg"
umount /tmp/frost-efi

echo ""
echo "=== Persist partition (p3) ==="
mkdir -p /tmp/frost-persist
mount -o ro ${LOOP}p3 /tmp/frost-persist
ls -la /tmp/frost-persist/
echo ""
ls -la /tmp/frost-persist/data/ 2>/dev/null || echo "No data dir"
umount /tmp/frost-persist

losetup -d "$LOOP"
