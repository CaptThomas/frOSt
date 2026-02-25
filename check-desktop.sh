#!/bin/bash
set -e
ROOTFS=/root/frost-build/rootfs

echo "=== LightDM config ==="
cat ${ROOTFS}/etc/lightdm/lightdm.conf 2>/dev/null || echo "NO lightdm.conf"

echo ""
echo "=== LightDM conf.d ==="
ls -la ${ROOTFS}/etc/lightdm/lightdm.conf.d/ 2>/dev/null || echo "no conf.d"
for f in ${ROOTFS}/etc/lightdm/lightdm.conf.d/*.conf; do
    if [ -f "$f" ]; then
        echo "--- $f ---"
        cat "$f" 2>/dev/null
    fi
done

echo ""
echo "=== Default session ==="
ls -la ${ROOTFS}/usr/share/xsessions/ 2>/dev/null

echo ""
echo "=== XFCE4 session desktop file ==="
cat ${ROOTFS}/usr/share/xsessions/xfce.desktop 2>/dev/null || echo "not found"

echo ""
echo "=== frost user home ==="
ls -la ${ROOTFS}/home/frost/ 2>/dev/null
echo ".dmrc:"
cat ${ROOTFS}/home/frost/.dmrc 2>/dev/null || echo "no .dmrc"

echo ""
echo "=== LightDM greeter config ==="
cat ${ROOTFS}/etc/lightdm/lightdm-gtk-greeter.conf 2>/dev/null || echo "not found"

echo ""
echo "=== Display managers installed ==="
dpkg --admindir=${ROOTFS}/var/lib/dpkg -l 2>/dev/null | grep -iE "gdm|sddm|lightdm|slim|nodm|lxdm|wdm|xdm" || echo "none"

echo ""
echo "=== Systemd default target ==="
readlink ${ROOTFS}/etc/systemd/system/default.target 2>/dev/null || echo "no default target override"
readlink ${ROOTFS}/lib/systemd/system/default.target 2>/dev/null || echo "no lib default target"

echo ""
echo "=== Display-manager service ==="
readlink ${ROOTFS}/etc/systemd/system/display-manager.service 2>/dev/null || echo "no display-manager.service link"
ls -la ${ROOTFS}/lib/systemd/system/lightdm.service 2>/dev/null || echo "no lightdm.service"

echo ""
echo "=== Xwrapper.config ==="
cat ${ROOTFS}/etc/X11/Xwrapper.config 2>/dev/null || echo "not found"

echo ""
echo "=== PAM lightdm-autologin ==="
cat ${ROOTFS}/etc/pam.d/lightdm-autologin 2>/dev/null || echo "not found"

echo ""
echo "=== Check xfce4 autostart files ==="
ls ${ROOTFS}/etc/xdg/autostart/ 2>/dev/null | grep -i xfce || echo "no xfce autostart"
ls ${ROOTFS}/home/frost/.config/autostart/ 2>/dev/null || echo "no user autostart"

echo ""
echo "=== Check screensaver / power manager ==="
dpkg --admindir=${ROOTFS}/var/lib/dpkg -l 2>/dev/null | grep -iE "screensaver|xscreensaver|light-locker|power" || echo "none"

echo ""
echo "=== Check getty/console autologin ==="
ls ${ROOTFS}/etc/systemd/system/getty@tty1.service.d/ 2>/dev/null || echo "no getty override"
cat ${ROOTFS}/etc/systemd/system/getty@tty1.service.d/*.conf 2>/dev/null || true

echo ""
echo "=== Check for X log locations ==="
ls -la ${ROOTFS}/var/log/Xorg* ${ROOTFS}/var/log/lightdm/ 2>/dev/null || echo "no X logs"

echo ""
echo "DONE"
