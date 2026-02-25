#!/bin/bash
set -e
ROOTFS=/root/frost-build/rootfs
KVER_NEW=$(ls ${ROOTFS}/lib/modules/ | sort -V | tail -1)
INITRAMFS_DIR=/root/frost-build/initramfs

echo "=== Problem 1: Module compression in initramfs ==="
echo "New kernel module format:"
find ${ROOTFS}/lib/modules/${KVER_NEW}/kernel/drivers/virtio -name "*.ko*" 2>/dev/null | head -3

echo ""
echo "Initramfs modules:"
find ${INITRAMFS_DIR}/lib/modules/${KVER_NEW}/kernel -name "*.ko*" 2>/dev/null | head -5

echo ""
echo "Can busybox modprobe handle .ko.xz?"
echo "Testing if busybox in initramfs supports xz..."
${INITRAMFS_DIR}/bin/busybox --list 2>/dev/null | grep -E "xz|unxz|lzma" || echo "NO xz support in busybox"

echo ""
echo "=== Problem 2: Missing firmware for kernel 6.12 ==="
# Decompress iwlwifi module to check firmware list
apt-get install -y -qq xz-utils 2>/dev/null || true
IWLMOD="${ROOTFS}/lib/modules/${KVER_NEW}/kernel/drivers/net/wireless/intel/iwlwifi/iwlwifi.ko.xz"
xz -d -k "${IWLMOD}" -c > /tmp/iwlwifi-612.ko 2>/dev/null

echo "Firmware requested by kernel 6.12 iwlwifi that is MISSING:"
modinfo /tmp/iwlwifi-612.ko 2>/dev/null | grep "^firmware:" | while read line; do
    fw=$(echo "$line" | awk '{print $2}')
    if [ ! -f "${ROOTFS}/lib/firmware/${fw}" ]; then
        echo "  MISSING: ${fw}"
    fi
done

echo ""
echo "Firmware requested by kernel 6.12 iwlwifi that EXISTS:"
modinfo /tmp/iwlwifi-612.ko 2>/dev/null | grep "^firmware:" | while read line; do
    fw=$(echo "$line" | awk '{print $2}')
    if [ -f "${ROOTFS}/lib/firmware/${fw}" ]; then
        echo "  OK: ${fw}"
    fi
done | grep -iE "Qu|cc" | head -10

rm -f /tmp/iwlwifi-612.ko

echo ""
echo "=== Problem 3: initramfs modprobe won't work with .ko.xz ==="
echo "Modules in initramfs are:"
file ${INITRAMFS_DIR}/lib/modules/${KVER_NEW}/kernel/drivers/virtio/virtio.ko* 2>/dev/null || echo "NO virtio in initramfs"
file ${INITRAMFS_DIR}/lib/modules/${KVER_NEW}/kernel/fs/overlayfs/overlay.ko* 2>/dev/null || echo "NO overlay in initramfs"

echo ""
echo "=== DIAGNOSIS ==="
echo "The kernel 6.12 uses .ko.xz compressed modules."
echo "busybox modprobe in the initramfs cannot handle .ko.xz."
echo "The initramfs modules need to be decompressed before packing."
echo ""
echo "Solution: Decompress all .ko.xz files in the initramfs to .ko"
echo ""
echo "=== DONE ==="
