#!/bin/bash
set -e
ROOTFS=/root/frost-build/rootfs

echo "========================================="
echo "  frOSt WiFi Deep Diagnosis"
echo "========================================="

echo ""
echo "=== 1. Wireless kernel modules in rootfs ==="
KVER=$(ls ${ROOTFS}/lib/modules/ | head -1)
echo "Kernel: $KVER"

echo ""
echo "--- cfg80211 (core wireless) ---"
find ${ROOTFS}/lib/modules/${KVER} -name "cfg80211*" 2>/dev/null || echo "NOT FOUND"

echo ""
echo "--- mac80211 ---"
find ${ROOTFS}/lib/modules/${KVER} -name "mac80211*" 2>/dev/null || echo "NOT FOUND"

echo ""
echo "--- Intel WiFi (iwlwifi) ---"
find ${ROOTFS}/lib/modules/${KVER} -name "iwl*" 2>/dev/null || echo "NOT FOUND"

echo ""
echo "--- Realtek WiFi ---"
find ${ROOTFS}/lib/modules/${KVER} -name "rtl*" -path "*/wireless/*" 2>/dev/null || echo "NOT FOUND"
find ${ROOTFS}/lib/modules/${KVER} -name "rtw*" 2>/dev/null || echo "NOT FOUND"

echo ""
echo "--- Atheros WiFi ---"
find ${ROOTFS}/lib/modules/${KVER} -name "ath*" -path "*/wireless/*" 2>/dev/null || echo "NOT FOUND"

echo ""
echo "--- Broadcom WiFi ---"
find ${ROOTFS}/lib/modules/${KVER} -name "b43*" -o -name "brcm*" 2>/dev/null | grep -v ".bin" || echo "NOT FOUND"

echo ""
echo "--- All wireless driver modules ---"
find ${ROOTFS}/lib/modules/${KVER}/kernel/drivers/net/wireless -name "*.ko*" 2>/dev/null | head -30 || echo "NO WIRELESS DRIVER DIR"

echo ""
echo "--- net/wireless core modules ---"
find ${ROOTFS}/lib/modules/${KVER}/kernel/net/wireless -name "*.ko*" 2>/dev/null || echo "NO NET/WIRELESS DIR"
find ${ROOTFS}/lib/modules/${KVER}/kernel/net/mac80211 -name "*.ko*" 2>/dev/null || echo "NO MAC80211 DIR"

echo ""
echo "=== 2. NetworkManager configuration ==="
echo "--- NetworkManager.conf ---"
cat ${ROOTFS}/etc/NetworkManager/NetworkManager.conf 2>/dev/null || echo "NOT FOUND"

echo ""
echo "--- NM system-connections ---"
ls -la ${ROOTFS}/etc/NetworkManager/system-connections/ 2>/dev/null || echo "EMPTY/MISSING"

echo ""
echo "--- NM conf.d ---"
ls -la ${ROOTFS}/etc/NetworkManager/conf.d/ 2>/dev/null || echo "EMPTY/MISSING"

echo ""
echo "=== 3. wpa_supplicant configuration ==="
cat ${ROOTFS}/etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null || echo "NOT FOUND"
ls -la ${ROOTFS}/etc/wpa_supplicant/ 2>/dev/null || echo "DIR NOT FOUND"

echo ""
echo "=== 4. Service enablement ==="
echo "--- display-manager ---"
readlink ${ROOTFS}/etc/systemd/system/display-manager.service 2>/dev/null || echo "NOT LINKED"
echo "--- multi-user.target.wants ---"
ls ${ROOTFS}/etc/systemd/system/multi-user.target.wants/ 2>/dev/null
echo "--- dbus symlinks ---"
ls ${ROOTFS}/etc/systemd/system/dbus-* 2>/dev/null || echo "No dbus symlinks"

echo ""
echo "=== 5. rfkill/crda ==="
ls -la ${ROOTFS}/usr/sbin/rfkill 2>/dev/null || ls -la ${ROOTFS}/usr/bin/rfkill 2>/dev/null || echo "No rfkill"
ls -la ${ROOTFS}/lib/firmware/regulatory.db 2>/dev/null || echo "No regulatory.db"

echo ""
echo "=== 6. iwlwifi firmware files ==="
ls ${ROOTFS}/lib/firmware/iwlwifi-* 2>/dev/null | wc -l
echo "iwlwifi firmware files"
ls ${ROOTFS}/lib/firmware/iwlwifi-* 2>/dev/null | head -5

echo ""
echo "=== 7. Checking if overlay prevents module loading ==="
echo "Modules in squashfs are read-only but modprobe should still work."
echo "Checking modprobe.d config..."
ls ${ROOTFS}/etc/modprobe.d/ 2>/dev/null
cat ${ROOTFS}/etc/modprobe.d/*.conf 2>/dev/null | head -20

echo ""
echo "=== DIAGNOSIS COMPLETE ==="
