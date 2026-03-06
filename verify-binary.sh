#!/bin/bash
# Verify exact binary in initramfs matches the source
set -e

IMG=/mnt/c/Users/thoma/Documents/frOSt/frost.img
SRC=/mnt/c/Users/thoma/Documents/frOSt
WORK=/tmp/frost-verify

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

# Mount EFI partition
mkdir -p "$WORK/efi"
mount "${LOOP}p1" "$WORK/efi"
cp "$WORK/efi/boot/initramfs.img" "$WORK/initramfs.cpio.gz"

echo "=== Initramfs on disk ==="
ls -la "$WORK/efi/boot/initramfs.img"
md5sum "$WORK/efi/boot/initramfs.img"

umount "$WORK/efi"
losetup -D

# Extract initramfs
cd "$WORK"
gunzip -f initramfs.cpio.gz 2>/dev/null || true
mkdir -p extracted
cd extracted
cpio -id < ../initramfs.cpio 2>/dev/null || cpio -id < ../initramfs.cpio.gz 2>/dev/null || true

echo ""
echo "=== early_init in initramfs ==="
ls -la early_init 2>/dev/null || echo "NO early_init found"
md5sum early_init 2>/dev/null || true

echo ""
echo "=== Does it have 'Frozen Operating System' (NEW) or 'frOSt Early Init v1.0' (OLD)? ==="
if strings early_init 2>/dev/null | grep -q "Frozen Operating System"; then
    echo ">>> NEW assembly detected"
else
    echo ">>> OLD assembly detected"
fi

if strings early_init 2>/dev/null | grep -q "finit_module\|Loading kernel modules.*asm"; then
    echo ">>> Has module loading code"
else
    echo ">>> NO module loading code"
fi

echo ""
echo "=== Check if rebuild output exists ==="
ls -la /root/frost-pyinit-build/early_init 2>/dev/null || echo "No rebuild output"
md5sum /root/frost-pyinit-build/early_init 2>/dev/null || true

echo ""
echo "=== Rebuild the assembly fresh NOW ==="
cd "$WORK"
nasm -f elf64 -o early_init_new.o "$SRC/boot/asm/early_init.asm"
ld -o early_init_new early_init_new.o --oformat=elf64-x86-64 -e _start --static
strip --strip-all early_init_new
echo "New build:"
ls -la early_init_new
md5sum early_init_new

echo ""
echo "=== Compare ==="
echo "Initramfs binary MD5: $(md5sum extracted/early_init 2>/dev/null | awk '{print $1}')"
echo "Fresh build MD5:      $(md5sum early_init_new | awk '{print $1}')"
echo "Previous rebuild MD5: $(md5sum /root/frost-pyinit-build/early_init 2>/dev/null | awk '{print $1}')"

if cmp -s extracted/early_init early_init_new; then
    echo ">>> MATCH: initramfs has current source code"
else
    echo ">>> MISMATCH: initramfs has STALE binary!"
fi

echo "=== DONE ==="
