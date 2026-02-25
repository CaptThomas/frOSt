#!/bin/bash
set -e
IMG=/root/frost-build/frost.img
OVMF=/mnt/c/Users/thoma/Documents/frOSt/OVMF.fd
SERIAL_LOG=/tmp/frost-serial.log

echo "=== QEMU boot test (kernel 6.12) ==="
rm -f $SERIAL_LOG

timeout 120 qemu-system-x86_64 \
    -drive "file=${IMG},format=raw,if=virtio" \
    -bios "${OVMF}" \
    -m 2048 \
    -cpu qemu64 \
    -smp 2 \
    -nographic \
    -chardev file,id=serial0,path=$SERIAL_LOG \
    -serial chardev:serial0 \
    -monitor none \
    -no-reboot \
    -name "frOSt-test" &

QEMU_PID=$!
echo "Waiting 110s..."
sleep 110

kill $QEMU_PID 2>/dev/null || true
wait $QEMU_PID 2>/dev/null || true

echo ""
echo "=== Boot messages ==="
strings $SERIAL_LOG | grep -iE "frOSt|Started|Failed|login|kernel|error" | head -30

echo ""
echo "=== Login prompt ==="
strings $SERIAL_LOG | grep "login:" | head -3

rm -f $SERIAL_LOG
echo "=== DONE ==="
