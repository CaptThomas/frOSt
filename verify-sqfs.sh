#!/bin/bash
set -e
MNT=/tmp/sqfs-verify
SQFS=/root/frost-build/rootfs.squashfs

echo "Squashfs: $(ls -lh $SQFS)"

# Clean up any existing mount
umount $MNT 2>/dev/null || true
rm -rf $MNT
mkdir -p $MNT

mount -t squashfs -o loop,ro $SQFS $MNT
echo "Mounted squashfs OK"

echo ""
echo "=== NetworkManager.conf ==="
cat $MNT/etc/NetworkManager/NetworkManager.conf

echo ""
echo "=== WiFi connection profile ==="
ls -la "$MNT/etc/NetworkManager/system-connections/"
cat "$MNT/etc/NetworkManager/system-connections/Intern WiFi.nmconnection" 2>/dev/null || echo "NOT FOUND"

echo ""
echo "=== wpa_supplicant.conf ==="
cat $MNT/etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null || echo "NOT FOUND"

echo ""
echo "=== /etc/network/interfaces ==="
cat $MNT/etc/network/interfaces 2>/dev/null || echo "NOT FOUND"

echo ""
echo "=== wpasupplicant ==="
grep "^Package: wpasupplicant" $MNT/var/lib/dpkg/status || echo "NOT FOUND"

echo ""
echo "=== iwlwifi firmware ==="
ls $MNT/lib/firmware/iwlwifi-* 2>/dev/null | wc -l
echo "files"

echo ""
echo "=== Xwrapper.config ==="
cat $MNT/etc/X11/Xwrapper.config 2>/dev/null || echo "NOT FOUND"

umount $MNT
rmdir $MNT
echo ""
echo "=== VERIFIED ==="
