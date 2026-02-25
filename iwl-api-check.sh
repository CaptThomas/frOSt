#!/bin/bash
set -e
ROOTFS=/root/frost-build/rootfs
KVER=$(ls ${ROOTFS}/lib/modules/ | sort -V | tail -1)

echo "=== 1. Check what firmware-iwlwifi package provides for 'so-a0-jf' ==="
dpkg --admindir=${ROOTFS}/var/lib/dpkg -L firmware-iwlwifi 2>/dev/null | grep "so-a0-jf" | sort

echo ""
echo "=== 2. Check what firmware-iwlwifi package provides for 'so-a0-hr' ==="
dpkg --admindir=${ROOTFS}/var/lib/dpkg -L firmware-iwlwifi 2>/dev/null | grep "so-a0-hr" | sort

echo ""
echo "=== 3. Check the exact iwl config used for AX201 in kernel 6.12 ==="
IWLMOD="${ROOTFS}/lib/modules/${KVER}/kernel/drivers/net/wireless/intel/iwlwifi/iwlwifi.ko.xz"
xz -d -k "$IWLMOD" -c > /tmp/iwl-check.ko 2>/dev/null

# Look for config structure names that map to PCI IDs
echo "Configurations referenced in module (grep for 'qu' and 'so'):"
strings /tmp/iwl-check.ko | grep -E "^iwl_(qu|so|ax201|cfg)" | sort -u | head -20

echo ""
echo "=== 4. Check firmware API min/max in module binary ==="
# The module has embedded config structs with api_max/api_min
# Try to find the pairs
strings /tmp/iwl-check.ko | grep -E "^iwlwifi-(QuZ|Qu|so|cc)-" | sort -u
echo ""
echo "Firmware name prefixes that the module tries (from format string):"
strings /tmp/iwl-check.ko | grep -oE 'iwlwifi-[A-Za-z0-9]+-[a-z0-9]+-[a-z0-9]+-[a-z0-9]+' | sort -u

echo ""
echo "=== 5. Verify the kernel that actually boots ==="
echo "vmlinuz in rootfs:"
ls -la ${ROOTFS}/boot/vmlinuz-* 2>/dev/null
echo ""
echo "vmlinuz in EFI (from image):"
# Check the disk image EFI partition
IMG=/root/frost-build/frost.img
if [ -f "$IMG" ]; then
    loop_dev=$(losetup --show -fP "$IMG" 2>/dev/null) || true
    if [ -n "$loop_dev" ]; then
        sleep 1
        partprobe "$loop_dev" 2>/dev/null || true
        sleep 1
        mkdir -p /tmp/efi-check
        mount "${loop_dev}p1" /tmp/efi-check 2>/dev/null || true
        echo "EFI vmlinuz:"
        file /tmp/efi-check/boot/vmlinuz 2>/dev/null || echo "not found"
        echo "EFI initramfs:"
        ls -la /tmp/efi-check/boot/initramfs.img 2>/dev/null || echo "not found"
        echo ""
        echo "GRUB config:"
        cat /tmp/efi-check/boot/grub/grub.cfg 2>/dev/null | head -20 || echo "not found"
        umount /tmp/efi-check 2>/dev/null || true
        rmdir /tmp/efi-check 2>/dev/null || true
        losetup -d "$loop_dev" 2>/dev/null || true
    fi
fi

echo ""
echo "=== 6. Try extracting API version from firmware file headers ==="
python3 << 'PYEOF'
import struct

for name in ['iwlwifi-QuZ-a0-hr-b0-77.ucode', 'iwlwifi-so-a0-hr-b0-89.ucode',
             'iwlwifi-so-a0-jf-b0-77.ucode']:
    path = '/root/frost-build/rootfs/lib/firmware/' + name
    try:
        with open(path, 'rb') as f:
            data = f.read(256)
            # TLV format: ver(4) + magic(4) + human_readable(null-terminated)
            ver = struct.unpack('<I', data[:4])[0]
            magic = data[4:8]
            # Find null terminator for human readable string
            null_idx = data.index(b'\x00', 8)
            human = data[8:null_idx].decode('ascii')
            print(f'{name}:')
            print(f'  Version: {ver}')
            print(f'  Magic: {magic}')
            print(f'  Human readable: {human}')
            # After hr string, there should be TLV entries
            # First TLV: type(4) + length(4) + value(length)
            pos = null_idx + 1
            # Align to 4 bytes
            pos = (pos + 3) & ~3
            tlv_type = struct.unpack('<I', data[pos:pos+4])[0]
            tlv_len = struct.unpack('<I', data[pos+4:pos+8])[0]
            print(f'  First TLV: type={tlv_type}, length={tlv_len}')
    except FileNotFoundError:
        print(f'{name}: FILE NOT FOUND')
    except Exception as e:
        print(f'{name}: ERROR - {e}')
PYEOF

rm -f /tmp/iwl-check.ko
echo ""
echo "=== DONE ==="
