#!/bin/bash
IMG=/mnt/c/Users/thoma/Documents/frOSt/frost.img
LOG=/tmp/frost-serial-uefi.log
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_VARS=/tmp/OVMF_VARS_tmp.fd

# Make a writable copy of OVMF vars
cp /usr/share/OVMF/OVMF_VARS_4M.fd $OVMF_VARS

echo "Starting QEMU (UEFI mode)..."
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
echo "=== SERIAL LOG ==="
head -200 $LOG
echo ""
echo "=== TOTAL LINES ==="
wc -l $LOG
