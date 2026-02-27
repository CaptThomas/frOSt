#!/bin/bash
IMG=/mnt/c/Users/thoma/Documents/frOSt/frost.img
LOG=/tmp/frost-test-hybrid.log
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_VARS=/tmp/OVMF_VARS_test.fd

cp /usr/share/OVMF/OVMF_VARS_4M.fd $OVMF_VARS

echo "Starting QEMU (UEFI mode, virtio disk)..."
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

echo ""
echo "=== frOSt/Python/error lines ==="
grep -iE 'frost|python|init|error|fatal|panic|switch_root|module|overlay|squash|mount|systemd|login|ready' $LOG | head -60

echo ""
echo "=== Last 40 lines ==="
tail -40 $LOG

echo ""
echo "Total lines: $(wc -l < $LOG)"
