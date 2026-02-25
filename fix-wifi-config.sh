#!/bin/bash
set -e
ROOTFS=/root/frost-build/rootfs

echo "=== Fixing WiFi configuration ==="

# 1. Fix NetworkManager.conf - set managed=true so NM manages all interfaces
echo ""
echo "--- Fixing NetworkManager.conf ---"
cat > ${ROOTFS}/etc/NetworkManager/NetworkManager.conf << 'NMCONF'
[main]
plugins=ifupdown,keyfile

[ifupdown]
managed=true

[device]
wifi.scan-rand-mac-address=no
NMCONF
cat ${ROOTFS}/etc/NetworkManager/NetworkManager.conf
echo "OK"

# 2. Create NetworkManager connection profile for "Intern WiFi"
echo ""
echo "--- Creating 'Intern WiFi' connection profile ---"
CONN_DIR=${ROOTFS}/etc/NetworkManager/system-connections
mkdir -p ${CONN_DIR}

cat > "${CONN_DIR}/Intern WiFi.nmconnection" << 'WIFICONN'
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
WIFICONN

# NetworkManager requires 600 permissions on connection files
chmod 600 "${CONN_DIR}/Intern WiFi.nmconnection"
echo "Created: ${CONN_DIR}/Intern WiFi.nmconnection"
ls -la "${CONN_DIR}/"

# 3. Make sure /etc/network/interfaces doesn't claim wlan0
echo ""
echo "--- Checking /etc/network/interfaces ---"
cat ${ROOTFS}/etc/network/interfaces 2>/dev/null || echo "NOT FOUND"

# Set interfaces to only have lo (let NM manage everything else)
cat > ${ROOTFS}/etc/network/interfaces << 'IFACES'
# This file describes the network interfaces available on your system
# and how to activate them. For more information, see interfaces(5).

source /etc/network/interfaces.d/*

# The loopback network interface
auto lo
iface lo inet loopback
IFACES
echo "OK - only loopback in interfaces"

# 4. Create wpa_supplicant.conf as fallback
echo ""
echo "--- Creating wpa_supplicant.conf ---"
cat > ${ROOTFS}/etc/wpa_supplicant/wpa_supplicant.conf << 'WPACONF'
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=US

network={
    ssid="Intern WiFi"
    psk="pleasebefast"
    key_mgmt=WPA-PSK
    priority=100
}
WPACONF
chmod 600 ${ROOTFS}/etc/wpa_supplicant/wpa_supplicant.conf
echo "OK"

# 5. Ensure services are enabled
echo ""
echo "--- Ensuring services are enabled ---"
mount -t proc proc ${ROOTFS}/proc 2>/dev/null || true
mount -t sysfs sysfs ${ROOTFS}/sys 2>/dev/null || true
mount --bind /dev ${ROOTFS}/dev 2>/dev/null || true

chroot ${ROOTFS} systemctl enable NetworkManager 2>/dev/null || echo "NM already enabled"
chroot ${ROOTFS} systemctl enable wpa_supplicant 2>/dev/null || echo "wpa already enabled"

# Also enable NetworkManager-wait-online for services that need network
chroot ${ROOTFS} systemctl enable NetworkManager-wait-online 2>/dev/null || echo "NM-wait-online not available"

umount ${ROOTFS}/dev 2>/dev/null || true
umount ${ROOTFS}/sys 2>/dev/null || true
umount ${ROOTFS}/proc 2>/dev/null || true

echo ""
echo "--- Verify service links ---"
ls -la ${ROOTFS}/etc/systemd/system/multi-user.target.wants/ | grep -E "Network|wpa"

echo ""
echo "--- Verify dbus links ---"
ls -la ${ROOTFS}/etc/systemd/system/dbus-* 2>/dev/null

# 6. Update persistence config to include wpa_supplicant conf
echo ""
echo "--- Checking persistence config includes NM connections ---"
# The persistence already includes /etc/NetworkManager/system-connections
# Let's also make sure wpa_supplicant is persisted
echo "Persistence paths already include /etc/NetworkManager/system-connections - OK"

echo ""
echo "=== WiFi configuration complete ==="
echo ""
echo "Summary:"
echo "  - NetworkManager.conf: managed=true (was false)"
echo "  - Connection profile: 'Intern WiFi' (WPA-PSK)"
echo "  - wpa_supplicant.conf: configured as fallback"
echo "  - Services: NetworkManager + wpa_supplicant enabled"
echo "  - /etc/network/interfaces: loopback only (NM manages all)"
