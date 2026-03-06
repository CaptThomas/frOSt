#!/bin/bash
# Check GRUB config and kernel built-in initramfs
set -e

IMG=/mnt/c/Users/thoma/Documents/frOSt/frost.img
WORK=/tmp/frost-grub-check

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

echo "=== GRUB config ==="
cat "$WORK/efi/boot/grub/grub.cfg"

echo ""
echo "=== All files in EFI boot ==="
find "$WORK/efi" -type f -ls

echo ""
echo "=== Check if kernel has built-in initramfs ==="
# Check if vmlinuz has an embedded initramfs
KERNEL="$WORK/efi/boot/vmlinuz"
echo "Kernel size: $(stat -c%s $KERNEL)"
# Extract kernel and check for embedded CPIO archive
SCRIPT=/tmp/extract-vmlinux.sh
cat > "$SCRIPT" << 'XEOF'
#!/bin/sh
# extract vmlinux from vmlinuz
for pos in $(grep -abo $'\x1f\x8b\x08' "$1" | cut -f1 -d:); do
    dd if="$1" bs=1 skip="$pos" 2>/dev/null | gunzip > /tmp/vmlinux-extracted 2>/dev/null && break
done
echo "Extracted vmlinux: $(stat -c%s /tmp/vmlinux-extracted 2>/dev/null || echo 'FAILED')"
# Check for CONFIG_INITRAMFS_SOURCE
strings /tmp/vmlinux-extracted 2>/dev/null | grep -i "initramfs\|Starting initramfs\|Early Init v1" | head -20
XEOF
chmod +x "$SCRIPT"
bash "$SCRIPT" "$KERNEL"

# Also check: does the initramfs on disk contain maybe TWO cpio archives stacked?
echo ""
echo "=== Check for concatenated cpio archives ==="
cp "$WORK/efi/boot/initramfs.img" "$WORK/initramfs-full.gz"
cd "$WORK"
# Count cpio magic sequences in the raw file
gunzip -c initramfs-full.gz 2>/dev/null | od -A x -t x1 | grep -c "30 37 30 37 30 31" || echo "Could not count"

umount "$WORK/efi"
losetup -D

echo "=== DONE ==="
