#!/bin/bash
# Test: just rebuild initramfs (fastest iteration)
set -e
IMG=/mnt/c/Users/thoma/Documents/frOSt/frost.img
SRC=/mnt/c/Users/thoma/Documents/frOSt
WORKDIR=/tmp/frost-init-rebuild

cleanup() {
    umount "${WORKDIR}/efi" 2>/dev/null || true
    LOOP=$(losetup -j "${IMG}" 2>/dev/null | head -1 | cut -d: -f1)
    [ -n "${LOOP}" ] && losetup -d "${LOOP}" 2>/dev/null || true
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

losetup -D 2>/dev/null || true
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"/{efi,initramfs}

losetup -fP "${IMG}"
LOOP=$(losetup -j "${IMG}" | head -1 | cut -d: -f1)
echo "LOOP=${LOOP}"

mount "${LOOP}p1" "${WORKDIR}/efi"

# Extract existing initramfs
cd "${WORKDIR}/initramfs"
gzip -dc "${WORKDIR}/efi/boot/initramfs.img" | cpio -id 2>/dev/null
echo "Extracted initramfs"

# Rebuild asm
if command -v nasm >/dev/null 2>&1; then
    nasm -f elf64 -o "${WORKDIR}/early_init.o" "${SRC}/boot/asm/early_init.asm"
    ld -o "${WORKDIR}/initramfs/early_init" "${WORKDIR}/early_init.o" --oformat=elf64-x86-64 -e _start --static
    strip --strip-all "${WORKDIR}/initramfs/early_init" 2>/dev/null || true
    chmod 755 "${WORKDIR}/initramfs/early_init"
    echo "ASM rebuilt"
fi

# Update init + frost_init.py
cp "${SRC}/initramfs/init" "${WORKDIR}/initramfs/init"
chmod 755 "${WORKDIR}/initramfs/init"
cp "${SRC}/initramfs/frost_init.py" "${WORKDIR}/initramfs/frost_init.py"
chmod 755 "${WORKDIR}/initramfs/frost_init.py"
echo "Init scripts updated"

# Repack
cd "${WORKDIR}/initramfs"
find . | cpio -o -H newc 2>/dev/null | gzip -9 > "${WORKDIR}/initramfs.cpio.gz"
cp "${WORKDIR}/initramfs.cpio.gz" "${WORKDIR}/efi/boot/initramfs.img"
echo "Initramfs repacked: $(du -h "${WORKDIR}/efi/boot/initramfs.img" | cut -f1)"
sync
echo "Done!"
