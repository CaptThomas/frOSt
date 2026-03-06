#!/bin/bash
# Check module paths that the assembly expects
set -eu

losetup -D 2>/dev/null || true
IMG=/mnt/c/Users/thoma/Documents/frOSt/frost.img
losetup -fP "$IMG"
sleep 2
LOOP=""
while IFS=: read -r dev rest; do
    LOOP="$dev"
    break
done < <(losetup -j "$IMG" 2>/dev/null)
echo "LOOP=$LOOP"

mkdir -p /tmp/cr /tmp/cs
mount "${LOOP}p2" /tmp/cr
mount -t squashfs -o ro,loop /tmp/cr/rootfs.squashfs /tmp/cs

KVER=$(ls /tmp/cs/lib/modules/ | head -1)
echo "KVER=$KVER"
BASE="/tmp/cs/lib/modules/$KVER/kernel"

echo "=== Checking assembly module paths ==="
for p in \
    drivers/scsi/scsi_common.ko \
    drivers/scsi/scsi_mod.ko \
    lib/t10-pi.ko \
    crypto/crct10dif_common.ko \
    crypto/crct10dif_generic.ko \
    lib/crc-t10dif.ko \
    crypto/crc32c_generic.ko \
    lib/crc64-rocksoft.ko \
    drivers/scsi/sd_mod.ko \
    drivers/scsi/sg.ko \
    drivers/ata/libata.ko \
    drivers/ata/ata_piix.ko \
    drivers/ata/ata_generic.ko \
    drivers/ata/libahci.ko \
    drivers/ata/ahci.ko \
    drivers/virtio/virtio.ko \
    drivers/virtio/virtio_ring.ko \
    drivers/virtio/virtio_pci.ko \
    drivers/virtio/virtio_pci_modern_dev.ko \
    drivers/virtio/virtio_pci_legacy_dev.ko \
    drivers/block/virtio_blk.ko \
    drivers/scsi/virtio_scsi.ko \
    drivers/net/virtio_net.ko \
    drivers/usb/common/usb-common.ko \
    drivers/usb/core/usbcore.ko \
    drivers/usb/host/xhci-hcd.ko \
    drivers/usb/host/xhci-pci.ko \
    drivers/usb/host/ehci-hcd.ko \
    drivers/usb/host/ehci-pci.ko \
    drivers/usb/storage/usb-storage.ko \
    fs/jbd2/jbd2.ko \
    fs/mbcache.ko \
    lib/crc16.ko \
    fs/ext4/ext4.ko \
    fs/squashfs/squashfs.ko \
    fs/overlayfs/overlay.ko \
    drivers/block/loop.ko \
    fs/fat/fat.ko \
    fs/fat/vfat.ko \
    fs/nls/nls_cp437.ko \
    fs/nls/nls_utf8.ko \
    fs/nls/nls_ascii.ko \
    drivers/hid/hid.ko \
    drivers/hid/usbhid/usbhid.ko \
    drivers/hid/hid-generic.ko \
    drivers/gpu/drm/drm.ko \
    drivers/gpu/drm/drm_kms_helper.ko \
    drivers/gpu/drm/bochs/bochs-drm.ko \
    drivers/gpu/drm/virtio/virtio-gpu.ko \
    drivers/gpu/drm/tiny/simpledrm.ko
do
    if [ -f "$BASE/$p" ]; then
        echo "OK   $p"
    else
        # Try to find the actual name
        dir=$(dirname "$p")
        name=$(basename "$p" .ko)
        found=$(find "$BASE/$dir" -name "${name}*" 2>/dev/null | head -1)
        if [ -n "$found" ]; then
            echo "DIFF $p -> $(basename "$found")"
        else
            echo "MISS $p"
        fi
    fi
done

echo ""
echo "=== Also check initramfs module paths ==="
IBASE=""
mkdir -p /tmp/ci
cd /tmp/ci
mount "${LOOP}p1" /tmp/ce 2>/dev/null || { mkdir -p /tmp/ce; mount "${LOOP}p1" /tmp/ce; }
zcat /tmp/ce/boot/initramfs.img 2>/dev/null | cpio -id 2>/dev/null
IBASE="/tmp/ci/lib/modules/$KVER/kernel"
if [ -d "$IBASE" ]; then
    for p in drivers/scsi/scsi_common.ko drivers/scsi/scsi_mod.ko drivers/virtio/virtio.ko fs/ext4/ext4.ko; do
        if [ -f "$IBASE/$p" ]; then
            echo "IRAM OK   $p"
        else
            echo "IRAM MISS $p"
        fi
    done
else
    echo "No kernel dir in initramfs at $IBASE"
    echo "Available:"
    find /tmp/ci/lib/modules/ -maxdepth 3 -type d 2>/dev/null
fi

umount /tmp/ce 2>/dev/null || true
umount /tmp/cs 2>/dev/null || true
umount /tmp/cr 2>/dev/null || true
losetup -D 2>/dev/null || true
rm -rf /tmp/ci /tmp/ce
