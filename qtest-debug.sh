#!/bin/bash
IMG=/mnt/c/Users/thoma/Documents/frOSt/frost.img
LOG=/tmp/frost-serial-debug.log
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_VARS=/tmp/OVMF_VARS_dbg.fd

cp /usr/share/OVMF/OVMF_VARS_4M.fd $OVMF_VARS

# Modify GRUB to auto-select Debug entry
LOOP_DEV=""
cleanup() {
    umount /tmp/frost-efi-tmp 2>/dev/null || true
    [ -n "$LOOP_DEV" ] && losetup -d $LOOP_DEV 2>/dev/null || true
}
trap cleanup EXIT

losetup -D 2>/dev/null || true
losetup -fP $IMG
sleep 1
LOOP_DEV=$(losetup -j $IMG | head -1 | cut -d: -f1)
sleep 1
partprobe $LOOP_DEV 2>/dev/null || true
sleep 1

mkdir -p /tmp/frost-efi-tmp
mount ${LOOP_DEV}p1 /tmp/frost-efi-tmp

# Set default to Debug entry (index 3) and timeout 1
sed -i 's/set default=0/set default=3/' /tmp/frost-efi-tmp/boot/grub/grub.cfg
sed -i 's/set timeout=3/set timeout=1/' /tmp/frost-efi-tmp/boot/grub/grub.cfg
sync
umount /tmp/frost-efi-tmp
losetup -d $LOOP_DEV
LOOP_DEV=""

echo "Starting QEMU (UEFI Debug mode)..."
timeout 90 qemu-system-x86_64 \
    -drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE \
    -drive if=pflash,format=raw,file=$OVMF_VARS \
    -drive file=$IMG,format=raw,if=virtio \
    -m 2048 -smp 2 \
    -nographic \
    -no-reboot \
    2>/dev/null > $LOG &
QP=$!
echo "QEMU PID: $QP"
sleep 75
kill $QP 2>/dev/null || true
wait $QP 2>/dev/null || true

# Restore GRUB to normal
losetup -fP $IMG
sleep 1
LOOP_DEV=$(losetup -j $IMG | head -1 | cut -d: -f1)
sleep 1
partprobe $LOOP_DEV 2>/dev/null || true
sleep 1
mount ${LOOP_DEV}p1 /tmp/frost-efi-tmp
sed -i 's/set default=3/set default=0/' /tmp/frost-efi-tmp/boot/grub/grub.cfg
sed -i 's/set timeout=1/set timeout=3/' /tmp/frost-efi-tmp/boot/grub/grub.cfg
sync
umount /tmp/frost-efi-tmp
losetup -d $LOOP_DEV
LOOP_DEV=""

echo ""
echo "=== SERIAL LOG (filtered for frOSt/Python/errors) ==="
grep -iE 'frost|python|init|error|fatal|panic|switch_root|module|overlay|squash|mount' $LOG | head -80

echo ""
echo "=== FULL LOG (last 60 lines) ==="
tail -60 $LOG

echo ""
echo "=== TOTAL LINES ==="
wc -l $LOG
