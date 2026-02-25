#!/bin/bash
set -e
ROOTFS=/root/frost-build/rootfs

echo "=== xscreensaver autostart ==="
cat ${ROOTFS}/etc/xdg/autostart/xscreensaver.desktop 2>/dev/null || echo "not found"

echo ""
echo "=== xscreensaver package ==="
dpkg --admindir=${ROOTFS}/var/lib/dpkg -l xscreensaver 2>/dev/null | tail -2 || echo "NOT INSTALLED"
dpkg --admindir=${ROOTFS}/var/lib/dpkg -l light-locker 2>/dev/null | tail -2 || echo "light-locker NOT INSTALLED"

echo ""
echo "=== xfce4-power-manager config ==="
cat ${ROOTFS}/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-power-manager.xml 2>/dev/null || echo "not found"

echo ""
echo "=== user power manager config ==="
cat ${ROOTFS}/home/frost/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-power-manager.xml 2>/dev/null || echo "not found"

echo ""
echo "=== xfce4 session config ==="
cat ${ROOTFS}/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-session.xml 2>/dev/null || echo "not found"

echo ""
echo "=== LightDM service file ==="
cat ${ROOTFS}/lib/systemd/system/lightdm.service 2>/dev/null || echo "not found"

echo ""
echo "=== All autostart desktop files ==="
for f in ${ROOTFS}/etc/xdg/autostart/*.desktop; do
    if [ -f "$f" ]; then
        echo "--- $(basename $f) ---"
        grep -E "^(Name|Exec|Hidden|AutostartCondition)" "$f" 2>/dev/null
    fi
done

echo ""
echo "=== DPMS / blanking Xorg config ==="
cat ${ROOTFS}/etc/X11/xorg.conf 2>/dev/null || echo "no xorg.conf"
cat ${ROOTFS}/etc/X11/xorg.conf.d/*.conf 2>/dev/null || echo "no xorg.conf.d"
ls ${ROOTFS}/usr/share/X11/xorg.conf.d/ 2>/dev/null

echo ""
echo "DONE"
