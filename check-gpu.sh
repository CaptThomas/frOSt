#!/bin/bash
set -e
ROOTFS=/root/frost-build/rootfs
KVER=$(ls ${ROOTFS}/lib/modules/ | sort -V | tail -1)

echo "=== 1. Check i915 GPU driver module ==="
find ${ROOTFS}/lib/modules/${KVER} -name "i915*" 2>/dev/null || echo "i915 NOT FOUND!"

echo ""
echo "=== 2. Check drm modules ==="
ls ${ROOTFS}/lib/modules/${KVER}/kernel/drivers/gpu/drm/*.ko* 2>/dev/null | head -10 || echo "no drm modules"
ls ${ROOTFS}/lib/modules/${KVER}/kernel/drivers/gpu/drm/i915/ 2>/dev/null | head -5 || echo "no i915 dir"

echo ""
echo "=== 3. Check i915 firmware ==="
ls ${ROOTFS}/lib/firmware/i915/ 2>/dev/null | head -20
echo "Count:"
ls ${ROOTFS}/lib/firmware/i915/ 2>/dev/null | wc -l

echo ""
echo "=== 4. Check Intel GPU firmware (Ice Lake) ==="
ls ${ROOTFS}/lib/firmware/i915/icl* 2>/dev/null || echo "no Ice Lake GPU firmware!"
ls ${ROOTFS}/lib/firmware/i915/tgl* 2>/dev/null | head -3

echo ""
echo "=== 5. Check video driver packages ==="
dpkg --admindir=${ROOTFS}/var/lib/dpkg -l 2>/dev/null | grep -iE "xserver-xorg-video|modesetting|intel" || echo "none"

echo ""
echo "=== 6. Check firmware-intel-graphics ==="
dpkg --admindir=${ROOTFS}/var/lib/dpkg -l firmware-intel-graphics 2>/dev/null | tail -2 || echo "NOT INSTALLED"

echo ""
echo "=== 7. Check Xorg logs for errors (from previous sessions if any) ==="
cat ${ROOTFS}/var/log/Xorg.0.log 2>/dev/null | grep -iE "(EE|WW)" | head -20 || echo "no Xorg log"

echo ""
echo "=== 8. Check xfce4-power-manager DPMS settings ==="
echo "Default xfwm settings:"
find ${ROOTFS} -name "xfce4-power-manager.xml" 2>/dev/null | head -5
find ${ROOTFS} -name "power.xml" 2>/dev/null | head -3
echo ""
echo "DPMS-related configs:"
find ${ROOTFS} -path "*/xfce4/*" -name "*.xml" 2>/dev/null | head -10

echo ""
echo "=== 9. Check if display server can find GPU ==="
# Check for Intel GPU card firmware
ls ${ROOTFS}/lib/firmware/i915/ 2>/dev/null | grep -i "icl\|tgl\|rkl\|adl\|ice" | head -10 || echo "no relevant GPU firmware"

echo ""
echo "=== 10. Check for screen blanking services ==="
find ${ROOTFS}/etc/xdg/autostart -name "*.desktop" -exec grep -l -i "screen\|blank\|lock\|saver\|dpms\|power" {} \; 2>/dev/null || echo "none"

echo ""
echo "DONE"
