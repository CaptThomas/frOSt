#!/bin/bash
set -e
ROOTFS=/root/frost-build/rootfs

echo "========================================="
echo "  Upgrading kernel + firmware via backports"
echo "========================================="

# Mount for chroot
mount -t proc proc ${ROOTFS}/proc 2>/dev/null || true
mount -t sysfs sysfs ${ROOTFS}/sys 2>/dev/null || true
mount --bind /dev ${ROOTFS}/dev 2>/dev/null || true
mount --bind /dev/pts ${ROOTFS}/dev/pts 2>/dev/null || true
cp /etc/resolv.conf ${ROOTFS}/etc/resolv.conf 2>/dev/null || true

# Add backports repository
echo ""
echo "=== Adding bookworm-backports ==="
if ! grep -q "backports" ${ROOTFS}/etc/apt/sources.list 2>/dev/null; then
    echo "deb http://deb.debian.org/debian bookworm-backports main contrib non-free non-free-firmware" >> ${ROOTFS}/etc/apt/sources.list
fi
cat ${ROOTFS}/etc/apt/sources.list

echo ""
echo "=== Updating package lists ==="
chroot ${ROOTFS} apt-get update -qq 2>&1

echo ""
echo "=== Available backports kernel ==="
chroot ${ROOTFS} apt-cache -t bookworm-backports search linux-image 2>/dev/null | grep -E "^linux-image-[0-9].*-amd64 " | head -5

echo ""
echo "=== Available backports firmware ==="
chroot ${ROOTFS} apt-cache -t bookworm-backports policy firmware-iwlwifi 2>/dev/null

echo ""
echo "=== Installing backports kernel ==="
chroot ${ROOTFS} env DEBIAN_FRONTEND=noninteractive apt-get install -y -t bookworm-backports linux-image-amd64 2>&1

echo ""
echo "=== Installing backports firmware ==="
chroot ${ROOTFS} env DEBIAN_FRONTEND=noninteractive apt-get install -y -t bookworm-backports firmware-iwlwifi firmware-misc-nonfree firmware-realtek firmware-atheros 2>&1

echo ""
echo "=== Kernel versions now installed ==="
ls ${ROOTFS}/lib/modules/

echo ""
echo "=== New kernel vmlinuz ==="
ls -la ${ROOTFS}/boot/vmlinuz-*

echo ""
echo "=== New firmware-iwlwifi version ==="
grep -A3 "^Package: firmware-iwlwifi" ${ROOTFS}/var/lib/dpkg/status | head -4

echo ""
echo "=== Check new iwlwifi module firmware list ==="
NEW_KVER=$(ls ${ROOTFS}/lib/modules/ | sort -V | tail -1)
echo "Newest kernel: $NEW_KVER"
modinfo ${ROOTFS}/lib/modules/${NEW_KVER}/kernel/drivers/net/wireless/intel/iwlwifi/iwlwifi.ko 2>/dev/null | grep "^firmware:" | grep -iE "Qu|cc|so" | head -20

echo ""
echo "=== Check QuZ firmware files (AX201) ==="
ls ${ROOTFS}/lib/firmware/iwlwifi-QuZ-* 2>/dev/null

echo ""
echo "=== Missing firmware for new kernel ==="
modinfo ${ROOTFS}/lib/modules/${NEW_KVER}/kernel/drivers/net/wireless/intel/iwlwifi/iwlwifi.ko 2>/dev/null | grep "^firmware:" | while read line; do
    fw=$(echo "$line" | awk '{print $2}')
    if [ ! -f "${ROOTFS}/lib/firmware/${fw}" ]; then
        echo "MISSING: ${fw}"
    fi
done

# Cleanup
umount ${ROOTFS}/dev/pts 2>/dev/null || true
umount ${ROOTFS}/dev 2>/dev/null || true
umount ${ROOTFS}/sys 2>/dev/null || true
umount ${ROOTFS}/proc 2>/dev/null || true

echo ""
echo "=== DONE ==="
