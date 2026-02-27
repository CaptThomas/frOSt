#!/bin/bash
# Check frost.img contents
set -e
IMG=/mnt/c/Users/thoma/Documents/frOSt/frost.img

echo "=== Image file ==="
ls -lh "$IMG"
file "$IMG"

losetup -D 2>/dev/null || true
sleep 1
losetup -fP "$IMG"
sleep 1
LOOP=$(losetup -j "$IMG" | head -1 | cut -d: -f1)
echo "LOOP=$LOOP"

echo ""
echo "=== Partition table ==="
fdisk -l "$LOOP"

echo ""
echo "=== Partition info ==="
for p in ${LOOP}p1 ${LOOP}p2 ${LOOP}p3; do
    if [ -b "$p" ]; then
        echo "$p: $(blkid "$p" 2>/dev/null)"
    fi
done

echo ""
echo "=== Root partition (p2) contents ==="
mkdir -p /tmp/frost-check
mount -o ro ${LOOP}p2 /tmp/frost-check
ls -la /tmp/frost-check/
echo ""

# Check for squashfs
if [ -f /tmp/frost-check/rootfs.squashfs ]; then
    echo "=== rootfs.squashfs found ==="
    file /tmp/frost-check/rootfs.squashfs
    ls -lh /tmp/frost-check/rootfs.squashfs

    echo ""
    echo "=== Squashfs contents (top-level) ==="
    mkdir -p /tmp/frost-sqfs
    mount -t squashfs -o ro,loop /tmp/frost-check/rootfs.squashfs /tmp/frost-sqfs
    ls /tmp/frost-sqfs/
    echo ""
    echo "Python: $(ls /tmp/frost-sqfs/usr/bin/python3* 2>/dev/null || echo 'NOT FOUND')"
    echo "Init: $(ls /tmp/frost-sqfs/sbin/init 2>/dev/null || echo 'NOT FOUND')"
    echo "Systemd: $(ls /tmp/frost-sqfs/lib/systemd/systemd 2>/dev/null || echo 'NOT FOUND')"
    echo "ld-linux: $(ls /tmp/frost-sqfs/lib64/ld-linux-x86-64.so.2 /tmp/frost-sqfs/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 2>/dev/null || echo 'NOT FOUND')"
    umount /tmp/frost-sqfs
else
    echo "NO rootfs.squashfs!"
    echo ""
    echo "Checking if p2 has rootfs directly..."
    ls /tmp/frost-check/sbin/init 2>/dev/null && echo "Has /sbin/init" || echo "No /sbin/init"
    ls /tmp/frost-check/usr/bin/python3* 2>/dev/null && echo "Has python3" || echo "No python3"
fi

umount /tmp/frost-check
losetup -d "$LOOP"
