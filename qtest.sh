#!/bin/bash
IMG=/mnt/c/Users/thoma/Documents/frOSt/frost.img
LOG=/tmp/frost-serial.log

echo "Starting QEMU..."
timeout 90 qemu-system-x86_64 -drive file=$IMG,format=raw -m 2048 -smp 2 -nographic -no-reboot 2>/dev/null > $LOG &
QP=$!
echo "QEMU PID: $QP"
sleep 75
kill $QP 2>/dev/null || true
wait $QP 2>/dev/null || true
echo "=== SERIAL LOG ==="
head -150 $LOG
echo ""
echo "=== LINES ==="
wc -l $LOG
