#!/bin/bash
# Test QEMU with serial as primary console for debugging init chain
IMG=/mnt/c/Users/thoma/Documents/frOSt/frost.img
LOG=/tmp/frost-serial-test.log
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_VARS=/tmp/OVMF_VARS_serial.fd
cp /usr/share/OVMF/OVMF_VARS_4M.fd $OVMF_VARS

# Modify GRUB to use serial as primary console
losetup -D 2>/dev/null || true
losetup -fP $IMG
sleep 1
LOOP=$(losetup -j $IMG | head -1 | cut -d: -f1)
sleep 1; partprobe $LOOP 2>/dev/null || true; sleep 1

mkdir -p /tmp/frost-efi-tmp
mount ${LOOP}p1 /tmp/frost-efi-tmp

cat > /tmp/frost-efi-tmp/boot/grub/grub.cfg << 'EOF'
set timeout=1
set default=0

menuentry "frOSt Serial Test" {
    linux /boot/vmlinuz root=LABEL=FROST_ROOT ro systemd.unit=multi-user.target loglevel=7 console=tty0 console=ttyS0,115200 systemd.journald.forward_to_console=1
    initrd /boot/initramfs.img
}
EOF

sync
umount /tmp/frost-efi-tmp
losetup -d $LOOP

echo "Starting QEMU (serial primary)..."
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

# Wait for boot to complete or timeout
sleep 90
kill $QP 2>/dev/null || true
wait $QP 2>/dev/null || true

# Restore GRUB
losetup -D 2>/dev/null || true
losetup -fP $IMG
sleep 1
LOOP=$(losetup -j $IMG | head -1 | cut -d: -f1)
sleep 1; partprobe $LOOP 2>/dev/null || true; sleep 1
mount ${LOOP}p1 /tmp/frost-efi-tmp
cat > /tmp/frost-efi-tmp/boot/grub/grub.cfg << 'EOF'
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
echo "=== INIT/PYTHON/SYSTEMD messages ==="
grep -iE 'frost|python|init|switch_root|overlay|squash|persist|systemd|login|getty|ready|started|reached|target|panic|fatal|error.*init' $LOG 2>/dev/null | head -60

echo ""
echo "=== Last 40 lines ==="
tail -40 $LOG

echo ""
echo "Total lines: $(wc -l < $LOG)"
