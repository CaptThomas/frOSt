#!/bin/bash
MNT=/tmp/persist-mount
mkdir -p $MNT
mount -o loop /mnt/c/Users/thoma/Documents/frOSt/persist-dump.img $MNT 2>/dev/null || true

# Copy all logs to Windows-accessible location
OUTDIR=/mnt/c/Users/thoma/Documents/frOSt/boot-logs
mkdir -p "$OUTDIR"

for f in $MNT/*.log; do
    if [ -f "$f" ]; then
        cp "$f" "$OUTDIR/"
    fi
done

echo "Logs copied to $OUTDIR"
ls -la "$OUTDIR/"

umount $MNT 2>/dev/null || true
