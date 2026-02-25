#!/bin/bash
set -e
ROOTFS=/root/frost-build/rootfs
KVER=$(ls ${ROOTFS}/lib/modules/ | sort -V | tail -1)

echo "=== 1. Check kmod installed (for proper modprobe after switch_root) ==="
dpkg --admindir=${ROOTFS}/var/lib/dpkg -l kmod 2>/dev/null | tail -2 || echo "kmod NOT installed"

echo ""
echo "=== 2. Check wireless module dependencies exist ==="
for mod in cfg80211 rfkill mac80211 libarc4; do
    found=$(find ${ROOTFS}/lib/modules/${KVER} -name "${mod}.ko*" 2>/dev/null | head -1)
    if [ -n "$found" ]; then
        echo "  OK: $mod -> $found"
    else
        echo "  MISSING: $mod"
    fi
done

echo ""
echo "=== 3. Check iwlwifi and iwlmvm exist ==="
find ${ROOTFS}/lib/modules/${KVER}/kernel/drivers/net/wireless/intel/iwlwifi -type f 2>/dev/null

echo ""
echo "=== 4. Check firmware symlinks vs actual files ==="
echo "QuZ firmware:"
ls -la ${ROOTFS}/lib/firmware/iwlwifi-QuZ-a0-hr-b0-77.ucode 2>/dev/null
echo "so firmware:"
ls -la ${ROOTFS}/lib/firmware/iwlwifi-so-a0-hr-b0-89.ucode 2>/dev/null
echo ""
echo "Any iwlwifi symlinks:"
find ${ROOTFS}/lib/firmware -name "iwlwifi-*" -type l 2>/dev/null | head -10 || echo "(no symlinks)"

echo ""
echo "=== 5. Check firmware file internal API version ==="
apt-get install -y -qq xz-utils 2>/dev/null || true
# Read first 16 bytes of firmware to check internal header
python3 -c "
import struct, sys
for name in ['iwlwifi-QuZ-a0-hr-b0-77.ucode', 'iwlwifi-so-a0-hr-b0-89.ucode']:
    path = '${ROOTFS}/lib/firmware/' + name
    try:
        with open(path, 'rb') as f:
            data = f.read(16)
            # IWL ucode header: magic(4) + ver(4) + api(4)
            # But format varies. Let's just show the header bytes
            print(f'{name}: first 16 bytes = {data[:16].hex()}')
            # TLV firmware starts with IWL_TLV_UCODE_MAGIC = 0x0a4c5749
            magic = struct.unpack('<I', data[:4])[0]
            print(f'  magic = 0x{magic:08x}')
            if magic == 0x0a4c5749:  # IWL_TLV_UCODE_MAGIC
                print('  Format: TLV (modern firmware)')
            else:
                print(f'  Format: unknown or legacy')
    except Exception as e:
        print(f'{name}: ERROR - {e}')
" 2>&1 || echo "python3 not available"

echo ""
echo "=== 6. Check /lib/firmware in squashfs (mounted check) ==="
mkdir -p /tmp/sqfs-check2
mount -o loop ${ROOTFS}.squashfs /tmp/sqfs-check2 2>/dev/null || mount -o loop /root/frost-build/rootfs.squashfs /tmp/sqfs-check2 2>/dev/null
echo "QuZ firmware in squashfs:"
ls -la /tmp/sqfs-check2/lib/firmware/iwlwifi-QuZ-a0-hr-b0-77.ucode 2>/dev/null || echo "MISSING"
echo "so firmware in squashfs:"
ls -la /tmp/sqfs-check2/lib/firmware/iwlwifi-so-a0-hr-b0-89.ucode 2>/dev/null || echo "MISSING"
echo ""
echo "Symlinks in squashfs firmware:"
find /tmp/sqfs-check2/lib/firmware -name "iwlwifi-*" -type l 2>/dev/null | head -5 || echo "(none)"
echo ""
echo "kmod binary in squashfs:"
ls -la /tmp/sqfs-check2/usr/bin/kmod /tmp/sqfs-check2/bin/kmod /tmp/sqfs-check2/sbin/modprobe 2>/dev/null
echo ""
echo "Wireless modules in squashfs:"
ls -la /tmp/sqfs-check2/lib/modules/${KVER}/kernel/net/wireless/cfg80211.ko* 2>/dev/null || echo "MISSING cfg80211"
ls -la /tmp/sqfs-check2/lib/modules/${KVER}/kernel/net/rfkill/rfkill.ko* 2>/dev/null || echo "MISSING rfkill"
ls -la /tmp/sqfs-check2/lib/modules/${KVER}/kernel/net/mac80211/mac80211.ko* 2>/dev/null || echo "MISSING mac80211"

echo ""
echo "=== 7. Check udev rules for iwlwifi ==="
find /tmp/sqfs-check2/lib/udev/rules.d /tmp/sqfs-check2/etc/udev/rules.d -name "*iwl*" -o -name "*firmware*" 2>/dev/null | head -5 || echo "(none)"

echo ""
echo "=== 8. Check if wpasupplicant is present ==="
ls -la /tmp/sqfs-check2/sbin/wpa_supplicant /tmp/sqfs-check2/usr/sbin/wpa_supplicant 2>/dev/null || echo "wpa_supplicant NOT FOUND"

umount /tmp/sqfs-check2 2>/dev/null
rmdir /tmp/sqfs-check2 2>/dev/null

echo ""
echo "=== DONE ==="
