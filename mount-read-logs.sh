#!/bin/bash
set -e
DUMP="/mnt/c/Users/thoma/Documents/frOSt/persist-dump.img"
MNT="/tmp/persist-mnt"
OUT="/mnt/c/Users/thoma/Documents/frOSt/boot-logs"

mkdir -p "$MNT" "$OUT"

# Mount the ext4 image
mount -o loop,ro "$DUMP" "$MNT" 2>/dev/null || {
    echo "Trying to fix filesystem first..."
    e2fsck -fy "$DUMP" 2>/dev/null || true
    mount -o loop,ro "$DUMP" "$MNT"
}

echo "=== Persist partition contents ==="
find "$MNT" -type f 2>/dev/null | head -50

echo ""
echo "=== Copying log files ==="
# Copy all log files
for f in $(find "$MNT" -name "*.log" -type f 2>/dev/null); do
    bn=$(basename "$f")
    cp "$f" "$OUT/$bn"
    echo "  Copied: $bn ($(wc -l < "$f") lines)"
done

# Also grab any other interesting files
for f in $(find "$MNT" -name "*.txt" -type f 2>/dev/null); do
    bn=$(basename "$f")
    cp "$f" "$OUT/$bn"
    echo "  Copied: $bn"
done

umount "$MNT"
rmdir "$MNT"

echo ""
echo "=== Done - logs in $OUT ==="
ls -la "$OUT/"
