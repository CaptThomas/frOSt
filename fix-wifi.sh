#!/bin/bash
# Quick fix: apply WiFi fixes to existing rootfs
set -e

IMG=/mnt/c/Users/thoma/Documents/frOSt/frost.img
WORKDIR=/tmp/frost-wifi-fix
SQFS_MNT="${WORKDIR}/sqfs"
ROOT_MNT="${WORKDIR}/root"
NEW_ROOTFS="${WORKDIR}/new-rootfs"

cleanup() {
    echo "[fix-wifi] Cleaning up..."
    umount "${SQFS_MNT}" 2>/dev/null || true
    umount "${ROOT_MNT}" 2>/dev/null || true
    LOOP=$(losetup -j "${IMG}" 2>/dev/null | head -1 | cut -d: -f1)
    [ -n "${LOOP}" ] && losetup -d "${LOOP}" 2>/dev/null || true
}
trap cleanup EXIT

echo "[fix-wifi] Setting up loop device..."
losetup -fP "${IMG}"
LOOP=$(losetup -j "${IMG}" | head -1 | cut -d: -f1)
echo "[fix-wifi] Loop: ${LOOP}"
ls ${LOOP}* 2>/dev/null

echo "[fix-wifi] Mounting FROST_ROOT partition (p2)..."
mkdir -p "${ROOT_MNT}" "${SQFS_MNT}" "${NEW_ROOTFS}"
mount "${LOOP}p2" "${ROOT_MNT}"

echo "[fix-wifi] Mounting squashfs..."
mount -t squashfs -o ro,loop "${ROOT_MNT}/rootfs.squashfs" "${SQFS_MNT}"

echo "[fix-wifi] Creating writable copy of rootfs..."
cp -a "${SQFS_MNT}/." "${NEW_ROOTFS}/"
umount "${SQFS_MNT}"

echo ""
echo "[fix-wifi] ====== Current WiFi state ======"
echo ""

# Check PNVM files
echo "[fix-wifi] PNVM files:"
ls -la "${NEW_ROOTFS}/lib/firmware/"iwlwifi-*pnvm* 2>/dev/null || echo "  (NONE FOUND - this may be an issue for AX201)"
echo ""

# Check firmware files for AX201
echo "[fix-wifi] AX201-related firmware (QuZ/so-a0-hr-b0):"
ls "${NEW_ROOTFS}/lib/firmware/"iwlwifi-QuZ* "${NEW_ROOTFS}/lib/firmware/"iwlwifi-so-a0-hr-b0* 2>/dev/null | head -10
echo ""

# Check current iwlwifi.conf
echo "[fix-wifi] Current modprobe config:"
cat "${NEW_ROOTFS}/etc/modprobe.d/iwlwifi.conf" 2>/dev/null || echo "  (not found)"
echo ""

# Check enabled services
echo "[fix-wifi] NetworkManager service:"
ls -la "${NEW_ROOTFS}/etc/systemd/system/multi-user.target.wants/NetworkManager.service" 2>/dev/null || echo "  NOT ENABLED"
echo "[fix-wifi] wpa_supplicant service:"
ls -la "${NEW_ROOTFS}/etc/systemd/system/multi-user.target.wants/wpa_supplicant.service" 2>/dev/null || echo "  NOT ENABLED"
echo ""

echo "[fix-wifi] ====== Applying fixes ======"
echo ""

# Fix 1: Remove enable_ini=0 from iwlwifi.conf
echo "[fix-wifi] Fix 1: Updating iwlwifi modprobe config (removing enable_ini=0)..."
cat > "${NEW_ROOTFS}/etc/modprobe.d/iwlwifi.conf" << 'EOF'
options iwlmvm power_scheme=1
EOF
echo "  Done. New config:"
cat "${NEW_ROOTFS}/etc/modprobe.d/iwlwifi.conf"
echo ""

# Fix 2: Enable NetworkManager.service
echo "[fix-wifi] Fix 2: Enabling NetworkManager.service..."
NM_UNIT="${NEW_ROOTFS}/lib/systemd/system/NetworkManager.service"
if [ -f "${NM_UNIT}" ]; then
    mkdir -p "${NEW_ROOTFS}/etc/systemd/system/multi-user.target.wants"
    ln -sf /lib/systemd/system/NetworkManager.service \
        "${NEW_ROOTFS}/etc/systemd/system/multi-user.target.wants/NetworkManager.service"
    echo "  Enabled (symlinked)"
else
    echo "  WARNING: NM unit file not found at ${NM_UNIT}"
    echo "  Available NM units:"
    find "${NEW_ROOTFS}/lib/systemd/system" -name "*NetworkManager*" -o -name "*network-manager*" 2>/dev/null
fi

# Also enable the NM dispatcher
NM_DISP="${NEW_ROOTFS}/lib/systemd/system/NetworkManager-dispatcher.service"
if [ -f "${NM_DISP}" ]; then
    ln -sf /lib/systemd/system/NetworkManager-dispatcher.service \
        "${NEW_ROOTFS}/etc/systemd/system/dbus-org.freedesktop.nm-dispatcher.service" 2>/dev/null || true
    echo "  NM dispatcher also enabled"
fi
echo ""

# Fix 3: Enable wpa_supplicant.service
echo "[fix-wifi] Fix 3: Enabling wpa_supplicant.service..."
WPA_UNIT="${NEW_ROOTFS}/lib/systemd/system/wpa_supplicant.service"
if [ -f "${WPA_UNIT}" ]; then
    mkdir -p "${NEW_ROOTFS}/etc/systemd/system/multi-user.target.wants"
    ln -sf /lib/systemd/system/wpa_supplicant.service \
        "${NEW_ROOTFS}/etc/systemd/system/multi-user.target.wants/wpa_supplicant.service"
    echo "  Enabled (symlinked)"
else
    echo "  WARNING: wpa_supplicant unit file not found at ${WPA_UNIT}"
    echo "  Available wpa units:"
    find "${NEW_ROOTFS}/lib/systemd/system" -name "*wpa*" 2>/dev/null
fi
echo ""

# Fix 4: Also install a WiFi diagnostic script into the rootfs
echo "[fix-wifi] Fix 4: Installing wifi-diag tool..."
cat > "${NEW_ROOTFS}/usr/local/bin/frost-wifi-diag" << 'DIAG'
#!/bin/bash
# frOSt WiFi Diagnostic Tool - run on real hardware to debug WiFi issues
echo "========================================="
echo "  frOSt WiFi Diagnostics"
echo "========================================="
echo ""

echo "--- Kernel ---"
uname -r
echo ""

echo "--- WiFi PCI Device ---"
lspci -nn 2>/dev/null | grep -iE 'network|wireless|wi-fi|wifi' || echo "(not found)"
echo ""

echo "--- iwlwifi module ---"
lsmod | grep iwl 2>/dev/null || echo "(not loaded)"
echo ""
echo "Module info:"
modinfo iwlwifi 2>/dev/null | head -5 || echo "(modinfo failed)"
echo ""

echo "--- Firmware loading (dmesg) ---"
dmesg 2>/dev/null | grep -iE 'iwlwifi|iwl.*firmware|iwl.*pnvm|iwl.*alive|iwl.*error|iwl.*fail' | tail -20 || echo "(no dmesg access)"
echo ""

echo "--- PNVM files ---"
ls -la /lib/firmware/iwlwifi-*pnvm* 2>/dev/null || echo "(none)"
echo ""

echo "--- rfkill ---"
rfkill list 2>/dev/null || echo "(rfkill not available)"
echo ""

echo "--- Network interfaces ---"
ip link show 2>/dev/null || echo "(ip not available)"
echo ""

echo "--- Wireless interfaces ---"
iw dev 2>/dev/null || echo "(iw not available)"
echo ""

echo "--- NetworkManager status ---"
systemctl status NetworkManager --no-pager 2>/dev/null | head -15 || echo "(NM not running)"
echo ""

echo "--- wpa_supplicant status ---"
systemctl status wpa_supplicant --no-pager 2>/dev/null | head -15 || echo "(wpa not running)"
echo ""

echo "--- nmcli device ---"
nmcli device 2>/dev/null || echo "(nmcli failed)"
echo ""

echo "--- nmcli radio ---"
nmcli radio 2>/dev/null || echo "(nmcli failed)"
echo ""

echo "--- modprobe config ---"
cat /etc/modprobe.d/iwlwifi.conf 2>/dev/null || echo "(not found)"
echo ""

echo "--- Module autoload config ---"
cat /etc/modules-load.d/iwlwifi.conf 2>/dev/null || echo "(not found)"
echo ""

echo "--- All loaded kernel modules (network-related) ---"
lsmod 2>/dev/null | grep -iE 'cfg80211|mac80211|iwl|rfkill|wlan|wifi|net' || echo "(none)"
echo ""

echo "--- D-Bus wpa_supplicant ---"
ls -la /usr/share/dbus-1/system-services/fi.w1.wpa_supplicant1.service 2>/dev/null || echo "(D-Bus activation file not found)"
echo ""

echo "========================================="
echo "  Diagnostics complete"
echo "========================================="
DIAG
chmod 755 "${NEW_ROOTFS}/usr/local/bin/frost-wifi-diag"
echo "  Installed: /usr/local/bin/frost-wifi-diag"
echo ""

echo "[fix-wifi] ====== Verification ======"
echo ""
echo "Services that will start at boot:"
ls "${NEW_ROOTFS}/etc/systemd/system/multi-user.target.wants/" 2>/dev/null
echo ""
echo "iwlwifi config:"
cat "${NEW_ROOTFS}/etc/modprobe.d/iwlwifi.conf"
echo ""

# Rebuild squashfs
echo "[fix-wifi] ====== Rebuilding squashfs ======"
echo ""
echo "[fix-wifi] Removing old squashfs..."
rm -f "${ROOT_MNT}/rootfs.squashfs"

echo "[fix-wifi] Building new squashfs (this takes a while)..."
mksquashfs "${NEW_ROOTFS}" "${ROOT_MNT}/rootfs.squashfs" \
    -comp xz -Xbcj x86 -b 256K -no-exports -noappend \
    -e boot/vmlinuz-* boot/initrd.img-* 2>&1 | tail -5

echo ""
echo "[fix-wifi] New squashfs size:"
ls -lh "${ROOT_MNT}/rootfs.squashfs"

echo ""
echo "[fix-wifi] Cleaning up temp rootfs..."
rm -rf "${NEW_ROOTFS}"

echo ""
echo "[fix-wifi] ====== Done! ======"
echo "[fix-wifi] Fixes applied:"
echo "  1. Removed enable_ini=0 (firmware v72+ needs INI tables for AX201)"
echo "  2. Enabled NetworkManager.service at boot"
echo "  3. Enabled wpa_supplicant.service at boot"
echo "  4. Installed frost-wifi-diag diagnostic tool"
echo ""
echo "[fix-wifi] Deploy to USB with: powershell ./deploy.ps1"
