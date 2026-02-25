#!/bin/bash
set -e

echo "=== Final verification of squashfs contents ==="

SQUASH=/root/frost-build/rootfs.squashfs
VERIFY_MNT=/tmp/frost-verify

mkdir -p $VERIFY_MNT
mount -t squashfs -o loop $SQUASH $VERIFY_MNT 2>/dev/null || {
    echo "Squashfs not rebuilt yet, checking rootfs directly"
    VERIFY_MNT=/root/frost-build/rootfs
}

echo ""
echo "=== WiFi packages ==="
for pkg in wpasupplicant iw wireless-tools rfkill wireless-regdb firmware-linux-free firmware-iwlwifi firmware-realtek firmware-atheros firmware-misc-nonfree; do
    if grep -q "^Package: $pkg$" $VERIFY_MNT/var/lib/dpkg/status 2>/dev/null; then
        echo "OK: $pkg"
    else
        echo "MISSING: $pkg"
    fi
done

echo ""
echo "=== Desktop packages ==="
for pkg in xfce4 xfce4-session lightdm lightdm-gtk-greeter xserver-xorg-core dbus-x11 policykit-1; do
    if grep -q "^Package: $pkg$" $VERIFY_MNT/var/lib/dpkg/status 2>/dev/null; then
        echo "OK: $pkg"
    else
        echo "MISSING: $pkg"
    fi
done

echo ""
echo "=== Critical binaries ==="
for bin in usr/sbin/wpa_supplicant usr/bin/Xorg usr/sbin/lightdm usr/bin/xfce4-session usr/sbin/NetworkManager; do
    if [ -f "$VERIFY_MNT/$bin" ]; then
        echo "OK: /$bin"
    else
        echo "MISSING: /$bin"
    fi
done

echo ""
echo "=== LightDM config ==="
cat $VERIFY_MNT/etc/lightdm/lightdm.conf 2>/dev/null || echo "MISSING"

echo ""
echo "=== display-manager.service ==="
ls -la $VERIFY_MNT/etc/systemd/system/display-manager.service 2>/dev/null || echo "MISSING"

echo ""
echo "=== Xwrapper.config ==="
cat $VERIFY_MNT/etc/X11/Xwrapper.config 2>/dev/null || echo "MISSING"

echo ""
echo "=== frost user groups ==="
grep "^frost:" $VERIFY_MNT/etc/passwd 2>/dev/null || echo "No frost user"
grep "frost" $VERIFY_MNT/etc/group 2>/dev/null | head -10

echo ""
echo "=== Firmware files ==="
find $VERIFY_MNT/lib/firmware/ -type f 2>/dev/null | wc -l
echo "firmware files"

echo ""
echo "=== Total packages ==="
grep -c "^Status: install ok installed" $VERIFY_MNT/var/lib/dpkg/status 2>/dev/null

umount $VERIFY_MNT 2>/dev/null || true
echo ""
echo "=== Verification complete ==="
