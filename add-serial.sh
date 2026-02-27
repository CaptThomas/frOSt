#!/bin/bash
# Add serial console to GRUB and test
set -e
IMG=/mnt/c/Users/thoma/Documents/frOSt/frost.img

losetup -D 2>/dev/null || true
losetup -fP "${IMG}"
sleep 1
LOOP=$(losetup -j "${IMG}" | head -1 | cut -d: -f1)
echo "Loop: ${LOOP}"
sleep 1
partprobe "${LOOP}" 2>/dev/null || true
sleep 1

mkdir -p /tmp/frost-efi
mount "${LOOP}p1" /tmp/frost-efi

echo "=== Current GRUB config ==="
cat /tmp/frost-efi/boot/grub/grub.cfg
echo ""

# Add serial console to GRUB
cat > /tmp/frost-efi/boot/grub/grub.cfg << 'GRUBCFG'
serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1
terminal_input serial console
terminal_output serial console

set timeout=3
set default=0
set color_normal=cyan/black
set color_highlight=white/blue

menuentry "frOSt Desktop" {
    linux /boot/vmlinuz root=LABEL=FROST_ROOT ro quiet splash loglevel=3 console=tty0 console=ttyS0,115200
    initrd /boot/initramfs.img
}

menuentry "frOSt Console" {
    linux /boot/vmlinuz root=LABEL=FROST_ROOT ro quiet systemd.unit=multi-user.target console=tty0 console=ttyS0,115200
    initrd /boot/initramfs.img
}

menuentry "frOSt Recovery" {
    linux /boot/vmlinuz root=LABEL=FROST_ROOT ro single console=tty0 console=ttyS0,115200
    initrd /boot/initramfs.img
}

menuentry "frOSt Debug" {
    linux /boot/vmlinuz root=LABEL=FROST_ROOT ro debug loglevel=7 console=tty0 console=ttyS0,115200
    initrd /boot/initramfs.img
}
GRUBCFG

echo "=== Updated GRUB config ==="
cat /tmp/frost-efi/boot/grub/grub.cfg

sync
umount /tmp/frost-efi
losetup -d "${LOOP}"
echo "Done"
