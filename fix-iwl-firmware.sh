#!/bin/bash
set -e
ROOTFS=/root/frost-build/rootfs
KVER=$(ls ${ROOTFS}/lib/modules/ | sort -V | tail -1)

log() { echo "[fix-iwl] $1"; }

# ==============================================
# Step 1: Download latest iwlwifi firmware from linux-firmware git
# ==============================================
log "Downloading latest iwlwifi firmware from linux-firmware.git..."

# Use shallow clone with sparse checkout for iwlwifi files only
FWDIR=/tmp/linux-firmware
rm -rf "$FWDIR"
cd /tmp
git clone --depth 1 --filter=blob:none --sparse \
    https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git \
    "$FWDIR" 2>&1 || {
    log "git.kernel.org failed, trying github mirror..."
    git clone --depth 1 --filter=blob:none --sparse \
        https://github.com/firmware-soc/linux-firmware.git \
        "$FWDIR" 2>&1
}

cd "$FWDIR"
git sparse-checkout set --no-cone '/iwlwifi-*' 2>&1

log "Downloaded firmware files:"
ls -la iwlwifi-* 2>/dev/null | wc -l
echo "files total"

# Copy ALL iwlwifi firmware files to rootfs
log "Installing firmware files..."
cp -v iwlwifi-*.ucode "${ROOTFS}/lib/firmware/" 2>&1 | tail -20
cp -v iwlwifi-*.pnvm "${ROOTFS}/lib/firmware/" 2>/dev/null || true

log "After update - firmware files in rootfs:"
ls ${ROOTFS}/lib/firmware/iwlwifi-*.ucode 2>/dev/null | wc -l
echo "ucode files"
ls ${ROOTFS}/lib/firmware/iwlwifi-*.pnvm 2>/dev/null | wc -l
echo "pnvm files"

# Check the specific files the module needs
log "Checking critical firmware files..."
IWLMOD="${ROOTFS}/lib/modules/${KVER}/kernel/drivers/net/wireless/intel/iwlwifi/iwlwifi.ko.xz"
xz -d -k "$IWLMOD" -c > /tmp/iwl-tmp.ko 2>/dev/null
modinfo /tmp/iwl-tmp.ko 2>/dev/null | grep "^firmware:" | while read line; do
    fw=$(echo "$line" | awk '{print $2}')
    if [ -f "${ROOTFS}/lib/firmware/${fw}" ]; then
        echo "  OK: ${fw}"
    else
        echo "  STILL MISSING: ${fw}"
    fi
done
rm -f /tmp/iwl-tmp.ko

# ==============================================
# Step 2: Add boot diagnostic service
# ==============================================
log "Creating boot diagnostic service..."

cat > "${ROOTFS}/etc/systemd/system/frost-dmesg-save.service" << 'SVCEOF'
[Unit]
Description=Save dmesg to persistence partition for debugging
After=local-fs.target
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'if [ -d /frost/persist ]; then dmesg > /frost/persist/dmesg-boot.log 2>&1; journalctl -b -u NetworkManager > /frost/persist/nm-boot.log 2>&1; ip link show > /frost/persist/ip-link.log 2>&1; rfkill list > /frost/persist/rfkill.log 2>&1; lspci -knn > /frost/persist/lspci.log 2>&1; fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF

# Enable the service
ln -sf /etc/systemd/system/frost-dmesg-save.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/frost-dmesg-save.service" 2>/dev/null || true

# Also add a delayed version that runs 30s after boot (to catch WiFi init)
cat > "${ROOTFS}/etc/systemd/system/frost-dmesg-save-delayed.service" << 'SVCEOF2'
[Unit]
Description=Save dmesg (delayed) for WiFi debugging
After=network-online.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 30
ExecStart=/bin/bash -c 'if [ -d /frost/persist ]; then dmesg > /frost/persist/dmesg-30s.log 2>&1; journalctl -b -u NetworkManager > /frost/persist/nm-30s.log 2>&1; nmcli device status > /frost/persist/nmcli-30s.log 2>&1; nmcli connection show > /frost/persist/nmcli-conn-30s.log 2>&1; lsmod > /frost/persist/lsmod-30s.log 2>&1; fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF2

ln -sf /etc/systemd/system/frost-dmesg-save-delayed.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/frost-dmesg-save-delayed.service" 2>/dev/null || true

# ==============================================
# Step 3: Ensure modprobe config is correct
# ==============================================
log "Setting up iwlwifi modprobe configuration..."

# Remove any blacklisting of iwlwifi
rm -f "${ROOTFS}/etc/modprobe.d/iwlwifi-blacklist.conf" 2>/dev/null || true

# Create iwlwifi module config
cat > "${ROOTFS}/etc/modprobe.d/iwlwifi.conf" << 'MODEOF'
# Enable verbose logging for iwlwifi debugging
# Remove or comment out the debug line once WiFi is working
options iwlwifi enable_ini=N
options iwlmvm power_scheme=1
MODEOF

# ==============================================
# Step 4: Ensure NetworkManager WiFi config is correct
# ==============================================
log "Verifying NetworkManager configuration..."

# NetworkManager.conf
cat "${ROOTFS}/etc/NetworkManager/NetworkManager.conf"

# WiFi connection
if [ -f "${ROOTFS}/etc/NetworkManager/system-connections/Intern WiFi.nmconnection" ]; then
    log "WiFi connection profile exists"
    cat "${ROOTFS}/etc/NetworkManager/system-connections/Intern WiFi.nmconnection"
else
    log "Creating WiFi connection profile..."
    mkdir -p "${ROOTFS}/etc/NetworkManager/system-connections"
    cat > "${ROOTFS}/etc/NetworkManager/system-connections/Intern WiFi.nmconnection" << 'WIFIEOF'
[connection]
id=Intern WiFi
uuid=a1b2c3d4-e5f6-7890-abcd-ef1234567890
type=wifi
autoconnect=true
autoconnect-priority=100

[wifi]
mode=infrastructure
ssid=Intern WiFi

[wifi-security]
key-mgmt=wpa-psk
psk=pleasebefast

[ipv4]
method=auto

[ipv6]
method=auto
addr-gen-mode=default

[proxy]
WIFIEOF
    chmod 600 "${ROOTFS}/etc/NetworkManager/system-connections/Intern WiFi.nmconnection"
fi

# ==============================================
# Step 5: Verify all wireless dependencies
# ==============================================
log "Checking wireless stack modules..."
for mod in rfkill cfg80211 mac80211 iwlwifi iwlmvm libarc4; do
    found=$(find "${ROOTFS}/lib/modules/${KVER}" -name "${mod}.ko*" 2>/dev/null | head -1)
    if [ -n "$found" ]; then
        echo "  OK: $mod"
    else
        echo "  MISSING: $mod (CRITICAL!)"
    fi
done

# ==============================================
# Step 6: Regenerate modules.dep
# ==============================================
log "Regenerating modules.dep..."
depmod -b "${ROOTFS}" "${KVER}" 2>/dev/null || log "depmod failed (non-fatal)"

# Verify
grep iwlwifi "${ROOTFS}/lib/modules/${KVER}/modules.dep" | head -3

# Cleanup
rm -rf "$FWDIR"

log "=== FIX COMPLETE ==="
log "Now rebuild squashfs and deploy."
