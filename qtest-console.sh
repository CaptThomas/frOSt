#!/bin/bash
# Test QEMU with forced serial output and console mode
IMG=/mnt/c/Users/thoma/Documents/frOSt/frost.img
LOG=/tmp/frost-console-test.log
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_VARS=/tmp/OVMF_VARS_con.fd
cp /usr/share/OVMF/OVMF_VARS_4M.fd $OVMF_VARS

# Temporarily modify GRUB to force Console mode with verbose output
losetup -D 2>/dev/null || true
losetup -fP $IMG
sleep 1
LOOP=$(losetup -j $IMG | head -1 | cut -d: -f1)
sleep 1; partprobe $LOOP 2>/dev/null || true; sleep 1

mkdir -p /tmp/frost-efi-tmp
mount ${LOOP}p1 /tmp/frost-efi-tmp

# Override GRUB to auto-boot Console with serial console and earlycon
cat > /tmp/frost-efi-tmp/boot/grub/grub.cfg << 'EOF'
serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1
terminal_input serial console
terminal_output serial console

set timeout=1
set default=0

menuentry "frOSt Console (Serial)" {
    linux /boot/vmlinuz root=LABEL=FROST_ROOT ro systemd.unit=multi-user.target loglevel=7 console=ttyS0,115200 console=tty0 earlycon=uart,io,0x3f8,115200n8 earlyprintk=serial,ttyS0,115200
    initrd /boot/initramfs.img
}
EOF

sync
umount /tmp/frost-efi-tmp
losetup -d $LOOP

echo "Starting QEMU (Console mode with serial)..."
timeout 120 qemu-system-x86_64 \
    -drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE \
    -drive if=pflash,format=raw,file=$OVMF_VARS \
    -drive file=$IMG,format=raw,if=virtio \
    -m 2048 -smp 2 \
    -nographic \
    -no-reboot \
    2>/dev/null > $LOG &
QP=$!
echo "QEMU PID: $QP"
sleep 100
kill $QP 2>/dev/null || true
wait $QP 2>/dev/null || true

# Restore GRUB
losetup -fP $IMG
sleep 1
LOOP=$(losetup -j $IMG | head -1 | cut -d: -f1)
sleep 1; partprobe $LOOP 2>/dev/null || true; sleep 1
mount ${LOOP}p1 /tmp/frost-efi-tmp
cat > /tmp/frost-efi-tmp/boot/grub/grub.cfg << 'EOF'
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
EOF
sync
umount /tmp/frost-efi-tmp
losetup -d $LOOP

echo ""
echo "=== SERIAL LOG (filtered) ==="
grep -iE 'frost|python|init|error|fatal|panic|switch_root|module|overlay|squash|mount|systemd|login|ready|started|reached|target' $LOG 2>/dev/null | head -80

echo ""
echo "=== Last 80 lines ==="
tail -80 $LOG

echo ""
echo "Total lines: $(wc -l < $LOG)"
