#!/bin/bash
set -e
ROOTFS=/root/frost-build/rootfs
KVER=$(ls ${ROOTFS}/lib/modules/ | sort -V | tail -1)

log() { echo "[fix-all] $1"; }

# ============================================================
# FIX 1: Desktop "replaced" issue - disable screen blanking
# ============================================================
log "=== FIX 1: Disable screen blanking / screensaver ==="

# 1a: Remove xscreensaver autostart
log "Removing xscreensaver autostart..."
rm -f "${ROOTFS}/etc/xdg/autostart/xscreensaver.desktop"

# 1b: Disable DPMS globally via Xorg config
log "Creating Xorg config to disable DPMS..."
mkdir -p "${ROOTFS}/etc/X11/xorg.conf.d"
cat > "${ROOTFS}/etc/X11/xorg.conf.d/10-no-dpms.conf" << 'XORGEOF'
Section "ServerFlags"
    Option "BlankTime"  "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime"    "0"
EndSection

Section "Extensions"
    Option "DPMS" "Disable"
EndSection
XORGEOF

# 1c: Configure xfce4-power-manager to never blank/suspend
log "Configuring xfce4-power-manager..."
cat > "${ROOTFS}/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-power-manager.xml" << 'PMEOF'
<?xml version="1.0" encoding="UTF-8"?>

<channel name="xfce4-power-manager" version="1.0">
  <property name="xfce4-power-manager" type="empty">
    <property name="power-button-action" type="uint" value="3"/>
    <property name="dpms-enabled" type="bool" value="false"/>
    <property name="dpms-on-ac-sleep" type="uint" value="0"/>
    <property name="dpms-on-ac-off" type="uint" value="0"/>
    <property name="dpms-on-battery-sleep" type="uint" value="0"/>
    <property name="dpms-on-battery-off" type="uint" value="0"/>
    <property name="blank-on-ac" type="int" value="0"/>
    <property name="blank-on-battery" type="int" value="0"/>
    <property name="brightness-on-ac" type="uint" value="9"/>
    <property name="brightness-on-battery" type="uint" value="9"/>
    <property name="inactivity-on-ac" type="uint" value="0"/>
    <property name="inactivity-on-battery" type="uint" value="0"/>
    <property name="inactivity-sleep-mode-on-ac" type="uint" value="1"/>
    <property name="inactivity-sleep-mode-on-battery" type="uint" value="1"/>
    <property name="lock-screen-suspend-hibernate" type="bool" value="false"/>
    <property name="logind-handle-lid-switch" type="bool" value="true"/>
    <property name="presentation-mode" type="bool" value="true"/>
  </property>
</channel>
PMEOF

# 1d: Also set it for the frost user
mkdir -p "${ROOTFS}/home/frost/.config/xfce4/xfconf/xfce-perchannel-xml"
cp "${ROOTFS}/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-power-manager.xml" \
   "${ROOTFS}/home/frost/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-power-manager.xml"
chown -R 1000:1000 "${ROOTFS}/home/frost/.config"

# 1e: Disable xscreensaver-related things
log "Disabling xscreensaver wrapper..."
rm -f "${ROOTFS}/usr/share/xscreensaver/xscreensaver-wrapper.sh" 2>/dev/null || true

# 1f: Create .dmrc for frost user
log "Creating .dmrc for frost user..."
cat > "${ROOTFS}/home/frost/.dmrc" << 'DMRCEOF'
[Desktop]
Session=xfce
DMRCEOF
chown 1000:1000 "${ROOTFS}/home/frost/.dmrc"

# 1g: Configure Intel GPU modesetting driver
log "Setting up Intel GPU Xorg config..."
cat > "${ROOTFS}/etc/X11/xorg.conf.d/20-intel.conf" << 'INTELEOF'
Section "Device"
    Identifier  "Intel Graphics"
    Driver      "modesetting"
    Option      "AccelMethod" "glamor"
    Option      "DRI" "3"
EndSection
INTELEOF

# ============================================================
# FIX 2: iwlwifi firmware - comprehensive approach
# ============================================================
log "=== FIX 2: iwlwifi firmware comprehensive fix ==="

# 2a: Remove old kernel 6.1 to save space and prevent confusion
log "Removing old kernel 6.1..."
rm -rf "${ROOTFS}/lib/modules/6.1.0-42-amd64"
rm -f "${ROOTFS}/boot/vmlinuz-6.1.0-42-amd64"
rm -f "${ROOTFS}/boot/config-6.1.0-42-amd64"
rm -f "${ROOTFS}/boot/System.map-6.1.0-42-amd64"
rm -f "${ROOTFS}/boot/initrd.img-6.1.0-42-amd64"

# 2b: Create a systemd service that explicitly loads iwlwifi and logs output
log "Creating iwlwifi loading service..."
cat > "${ROOTFS}/etc/systemd/system/frost-load-iwlwifi.service" << 'IWLSVC'
[Unit]
Description=Load iwlwifi driver with explicit firmware path
After=systemd-modules-load.service
Before=NetworkManager.service
DefaultDependencies=no

[Service]
Type=oneshot
# Wait a moment for filesystem to be fully ready
ExecStartPre=/bin/sleep 2
# Load modules in order
ExecStart=/sbin/modprobe rfkill
ExecStart=/sbin/modprobe cfg80211
ExecStart=/sbin/modprobe mac80211
ExecStart=/sbin/modprobe iwlwifi
ExecStart=/sbin/modprobe iwlmvm
# Log the result
ExecStartPost=/bin/bash -c 'dmesg | grep -i iwl > /tmp/iwlwifi-load.log 2>&1 || true'
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
IWLSVC
ln -sf /etc/systemd/system/frost-load-iwlwifi.service \
    "${ROOTFS}/etc/systemd/system/sysinit.target.wants/frost-load-iwlwifi.service" 2>/dev/null || true

# 2c: Add iwlwifi firmware to initramfs as well
log "Adding iwlwifi firmware to initramfs..."
INITRAMFS_DIR="/root/frost-build/initramfs"
mkdir -p "${INITRAMFS_DIR}/lib/firmware"
# Copy ALL iwlwifi firmware for AX201 (QuZ and so families + dependencies)
for prefix in QuZ-a0-hr-b0 QuZ-a0-jf-b0 Qu-b0-hr-b0 Qu-c0-hr-b0 so-a0-hr-b0 so-a0-gf-a0 cc-a0; do
    for f in ${ROOTFS}/lib/firmware/iwlwifi-${prefix}*.ucode; do
        if [ -f "$f" ]; then
            cp "$f" "${INITRAMFS_DIR}/lib/firmware/"
            log "  Added to initramfs: $(basename $f)"
        fi
    done
done
# PNVM files
for f in ${ROOTFS}/lib/firmware/iwlwifi-*.pnvm; do
    if [ -f "$f" ]; then
        cp "$f" "${INITRAMFS_DIR}/lib/firmware/"
        log "  Added PNVM: $(basename $f)"
    fi
done
# Also add i915 firmware for Intel GPU
mkdir -p "${INITRAMFS_DIR}/lib/firmware/i915"
for f in ${ROOTFS}/lib/firmware/i915/icl_*.bin; do
    if [ -f "$f" ]; then
        cp "$f" "${INITRAMFS_DIR}/lib/firmware/i915/"
        log "  Added GPU fw: $(basename $f)"
    fi
done

# 2d: Ensure modules.dep is regenerated
log "Regenerating modules.dep..."
depmod -b "${ROOTFS}" "${KVER}" 2>/dev/null || true

# 2e: Ensure NetworkManager connection in system-connections has correct permissions
log "Fixing WiFi connection file permissions..."
chmod 600 "${ROOTFS}/etc/NetworkManager/system-connections/Intern WiFi.nmconnection" 2>/dev/null || true

# 2f: Update the dmesg capture services
log "Updating diagnostic services..."
cat > "${ROOTFS}/etc/systemd/system/frost-dmesg-save.service" << 'SVCEOF'
[Unit]
Description=Save boot diagnostics to persistence
After=local-fs.target network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'sleep 5; if [ -d /frost/persist ]; then dmesg > /frost/persist/dmesg-boot.log 2>&1; journalctl -b > /frost/persist/journal-boot.log 2>&1; ip link show > /frost/persist/ip-link.log 2>&1; rfkill list > /frost/persist/rfkill.log 2>&1; lspci -knn > /frost/persist/lspci.log 2>&1; lsmod > /frost/persist/lsmod.log 2>&1; cat /tmp/iwlwifi-load.log > /frost/persist/iwlwifi-load.log 2>&1; fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF

cat > "${ROOTFS}/etc/systemd/system/frost-dmesg-save-delayed.service" << 'SVCEOF2'
[Unit]
Description=Save boot diagnostics (delayed, after WiFi init)
After=network-online.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 45
ExecStart=/bin/bash -c 'if [ -d /frost/persist ]; then dmesg > /frost/persist/dmesg-45s.log 2>&1; nmcli device status > /frost/persist/nmcli-dev.log 2>&1; nmcli connection show > /frost/persist/nmcli-conn.log 2>&1; journalctl -b -u NetworkManager > /frost/persist/nm.log 2>&1; iwconfig > /frost/persist/iwconfig.log 2>&1; cat /var/log/Xorg.0.log > /frost/persist/xorg.log 2>&1; fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF2

# Ensure enabled
mkdir -p "${ROOTFS}/etc/systemd/system/multi-user.target.wants"
mkdir -p "${ROOTFS}/etc/systemd/system/sysinit.target.wants"
ln -sf /etc/systemd/system/frost-dmesg-save.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/frost-dmesg-save.service"
ln -sf /etc/systemd/system/frost-dmesg-save-delayed.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/frost-dmesg-save-delayed.service"

log "=== ALL FIXES APPLIED ==="
log "Old kernel 6.1 removed"
log "xscreensaver autostart removed"
log "DPMS disabled via Xorg and xfce4-power-manager"
log "Intel GPU modesetting configured"
log "iwlwifi explicit loading service created"
log "iwlwifi firmware added to initramfs"
log "Diagnostic services updated"
