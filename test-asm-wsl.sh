#!/bin/bash
# Run QEMU boot test and analyze output
set -e
cd /mnt/c/Users/thoma/Documents/frOSt

# Clean up
rm -f /tmp/qemu-frost-test.log

# Run QEMU in background  
timeout 50 /mnt/c/Program\ Files/qemu/qemu-system-x86_64.exe \
    -m 2048 -smp 2 \
    -kernel vmlinuz-test \
    -initrd initramfs-test.img \
    -append "root=LABEL=FROST_ROOT ro console=ttyS0,115200 loglevel=4" \
    -drive file=frost.img,format=raw,if=virtio \
    -serial file:/tmp/qemu-frost-test.log \
    -display none \
    -no-reboot 2>/dev/null &

QEMU_PID=$!
sleep 50
kill $QEMU_PID 2>/dev/null || true
wait $QEMU_PID 2>/dev/null || true

# Analyze output
if [ -f /tmp/qemu-frost-test.log ]; then
    echo "=== LOG SIZE ==="
    wc -c /tmp/qemu-frost-test.log
    echo "=== STRIPPED LAST 100 LINES ==="
    sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' /tmp/qemu-frost-test.log | tail -100
else
    echo "NO LOG FILE"
fi
