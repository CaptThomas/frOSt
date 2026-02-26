#!/bin/bash
# Verify WiFi fixes in the rebuilt squashfs
set -e

IMG=/mnt/c/Users/thoma/Documents/frOSt/frost.img
losetup -D 2>/dev/null || true
losetup -fP "${IMG}"
LOOP=$(losetup -j "${IMG}" | head -1 | cut -d: -f1)
echo "LOOP=${LOOP}"

mkdir -p /tmp/fcheck/root /tmp/fcheck/sqfs
mount "${LOOP}p2" /tmp/fcheck/root
mount -t squashfs -o ro,loop /tmp/fcheck/root/rootfs.squashfs /tmp/fcheck/sqfs

echo ""
echo "=== PNVM files ==="
ls -la /tmp/fcheck/sqfs/lib/firmware/iwlwifi-*pnvm* 2>/dev/null || echo "(none)"

echo ""
echo "=== AX201 firmware files ==="
ls /tmp/fcheck/sqfs/lib/firmware/iwlwifi-QuZ* /tmp/fcheck/sqfs/lib/firmware/iwlwifi-so-a0-hr* 2>/dev/null || echo "(none)"

echo ""
echo "=== iwlwifi modprobe config ==="
cat /tmp/fcheck/sqfs/etc/modprobe.d/iwlwifi.conf 2>/dev/null || echo "(not found)"

echo ""
echo "=== Enabled services (multi-user) ==="
ls /tmp/fcheck/sqfs/etc/systemd/system/multi-user.target.wants/ 2>/dev/null || echo "(none)"

echo ""
echo "=== D-Bus wpa_supplicant ==="
ls -la /tmp/fcheck/sqfs/usr/share/dbus-1/system-services/fi.w1.wpa_supplicant1.service 2>/dev/null || echo "(not found)"

echo ""
echo "=== wpa_supplicant binary ==="
ls -la /tmp/fcheck/sqfs/usr/sbin/wpa_supplicant 2>/dev/null || echo "(not found)"

echo ""
echo "=== NM wifi plugin ==="
find /tmp/fcheck/sqfs/usr/lib -name "libnm-device-plugin-wifi*" 2>/dev/null || echo "(not found)"

echo ""
echo "=== frost-wifi-diag ==="
ls -la /tmp/fcheck/sqfs/usr/local/bin/frost-wifi-diag 2>/dev/null || echo "(not found)"

echo ""
echo "=== NM dbus service ==="
ls -la /tmp/fcheck/sqfs/etc/systemd/system/dbus-org.freedesktop.nm-dispatcher.service 2>/dev/null || echo "(not found)"

umount /tmp/fcheck/sqfs 2>/dev/null || true
umount /tmp/fcheck/root 2>/dev/null || true
losetup -d "${LOOP}" 2>/dev/null || true
rm -rf /tmp/fcheck
echo ""
echo "=== Done ==="
