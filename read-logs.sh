#!/bin/bash
set -e
MNT=/tmp/persist-mount

# Check if mounted
if ! mountpoint -q $MNT 2>/dev/null; then
    mount -o loop /mnt/c/Users/thoma/Documents/frOSt/persist-dump.img $MNT 2>/dev/null
fi

echo "=========================================="
echo "=== iwlwifi-load.log ==="
echo "=========================================="
cat $MNT/iwlwifi-load.log 2>/dev/null || echo "(empty or not found)"

echo ""
echo "=========================================="
echo "=== iwconfig.log ==="
echo "=========================================="
cat $MNT/iwconfig.log 2>/dev/null || echo "(empty or not found)"

echo ""
echo "=========================================="
echo "=== rfkill.log ==="
echo "=========================================="
cat $MNT/rfkill.log 2>/dev/null || echo "(empty or not found)"

echo ""
echo "=========================================="
echo "=== lspci.log ==="
echo "=========================================="
cat $MNT/lspci.log 2>/dev/null || echo "(empty or not found)"

echo ""
echo "=========================================="
echo "=== ip-link.log ==="
echo "=========================================="
cat $MNT/ip-link.log 2>/dev/null || echo "(empty or not found)"

echo ""
echo "=========================================="
echo "=== nmcli-dev.log ==="
echo "=========================================="
cat $MNT/nmcli-dev.log 2>/dev/null || echo "(empty or not found)"

echo ""
echo "=========================================="
echo "=== nmcli-conn.log ==="
echo "=========================================="
cat $MNT/nmcli-conn.log 2>/dev/null || echo "(empty or not found)"

echo ""
echo "=========================================="
echo "=== lsmod.log (wireless related) ==="
echo "=========================================="
grep -iE "iwl|cfg80211|mac80211|rfkill|wlan|wifi" $MNT/lsmod.log 2>/dev/null || echo "(none)"

echo ""
echo "=========================================="
echo "=== dmesg iwlwifi messages ==="
echo "=========================================="
grep -i "iwl" $MNT/dmesg-boot.log 2>/dev/null | head -50 || echo "(none)"

echo ""
echo "=========================================="
echo "=== dmesg firmware messages ==="
echo "=========================================="
grep -iE "firmware|fw_" $MNT/dmesg-boot.log 2>/dev/null | head -30 || echo "(none)"

echo ""
echo "=========================================="
echo "=== dmesg wifi/wlan messages ==="
echo "=========================================="
grep -iE "wlan|wifi|wireless|80211" $MNT/dmesg-boot.log 2>/dev/null | head -20 || echo "(none)"

echo ""
echo "=========================================="
echo "=== dmesg error/warning messages ==="
echo "=========================================="
grep -iE "\berror\b|\bfail\b|\bwarn\b" $MNT/dmesg-boot.log 2>/dev/null | grep -v "ACPI" | head -30 || echo "(none)"

echo ""
echo "=========================================="
echo "=== Xorg errors ==="
echo "=========================================="
grep -E "^\(EE\)" $MNT/xorg.log 2>/dev/null | head -20 || echo "(none)"
echo "---"
grep -E "^\(WW\)" $MNT/xorg.log 2>/dev/null | head -10 || echo "(none)"

echo ""
echo "=========================================="
echo "=== NetworkManager log (last 30 lines) ==="
echo "=========================================="
tail -30 $MNT/nm.log 2>/dev/null || echo "(empty)"
