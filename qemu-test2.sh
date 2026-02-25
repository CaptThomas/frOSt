#!/bin/bash
set -e
IMG=/root/frost-build/frost.img
OVMF=/mnt/c/Users/thoma/Documents/frOSt/OVMF.fd
SERIAL_LOG=/tmp/frost-serial.log

echo "=== QEMU boot test with service check ==="
rm -f $SERIAL_LOG

# Start QEMU with serial to file, monitor on stdio
timeout 150 qemu-system-x86_64 \
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
echo "QEMU PID: $QEMU_PID"

# Wait for boot to complete
echo "Waiting for boot (100s)..."
sleep 100

echo "=== Serial output ==="
cat $SERIAL_LOG

# Kill QEMU
kill $QEMU_PID 2>/dev/null || true
wait $QEMU_PID 2>/dev/null || true

echo ""
echo "=== Checking for key boot messages ==="
echo "--- frOSt init messages ---"
grep -o "\[frOSt\].*" $SERIAL_LOG 2>/dev/null || echo "No frOSt messages"
echo ""
echo "--- systemd messages ---"
grep -i "systemd\|Started\|Reached\|failed\|error" $SERIAL_LOG 2>/dev/null | tail -50 || echo "No systemd messages"
echo ""
echo "--- Login prompt ---"
grep -i "login:" $SERIAL_LOG 2>/dev/null || echo "No login prompt found"

rm -f $SERIAL_LOG
echo "=== Test complete ==="
