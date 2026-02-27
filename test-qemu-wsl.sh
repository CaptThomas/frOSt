#!/bin/bash
# Test frOSt boot in QEMU (WSL) with serial capture
set -e
IMG=/mnt/c/Users/thoma/Documents/frOSt/frost.img
SERIAL_LOG=/tmp/frost-serial.log

echo "Starting QEMU boot test..."

# Run QEMU with nographic (serial to stdout)
timeout 90 qemu-system-x86_64 \
    -drive file="${IMG}",format=raw \
    -m 2048 -smp 2 \
    -nographic \
    -no-reboot \
    2>/dev/null | tee "${SERIAL_LOG}" &
QEMU_PID=$!

# Wait and then kill
sleep 75
kill $QEMU_PID 2>/dev/null || true
wait $QEMU_PID 2>/dev/null || true

echo ""
echo "=== Boot test complete ==="
echo "Lines captured: $(wc -l < ${SERIAL_LOG})"
