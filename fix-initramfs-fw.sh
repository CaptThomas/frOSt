#!/bin/bash
set -e
BUILD_DIR="/root/frost-build"
ROOTFS_DIR="${BUILD_DIR}/rootfs"
INITRAMFS_DIR="${BUILD_DIR}/initramfs"
KVER=$(ls ${ROOTFS_DIR}/lib/modules/ | sort -V | tail -1)

log() { echo "[fix-initramfs] $1"; }

# Add iwlwifi firmware to initramfs
log "Adding iwlwifi firmware to initramfs..."
mkdir -p "${INITRAMFS_DIR}/lib/firmware"

for prefix in QuZ-a0-hr-b0 QuZ-a0-jf-b0 Qu-b0-hr-b0 Qu-b0-jf-b0 Qu-c0-hr-b0 Qu-c0-jf-b0 so-a0-hr-b0 so-a0-gf-a0 so-a0-jf-b0 cc-a0; do
    for f in ${ROOTFS_DIR}/lib/firmware/iwlwifi-${prefix}*.ucode; do
        [ -f "$f" ] && cp "$f" "${INITRAMFS_DIR}/lib/firmware/"
    done
done

# PNVM files
for f in ${ROOTFS_DIR}/lib/firmware/iwlwifi-*.pnvm; do
    [ -f "$f" ] && cp "$f" "${INITRAMFS_DIR}/lib/firmware/"
done

# i915 firmware
mkdir -p "${INITRAMFS_DIR}/lib/firmware/i915"
for f in ${ROOTFS_DIR}/lib/firmware/i915/icl_*.bin; do
    [ -f "$f" ] && cp "$f" "${INITRAMFS_DIR}/lib/firmware/i915/"
done

log "Firmware files in initramfs:"
ls ${INITRAMFS_DIR}/lib/firmware/iwlwifi-* 2>/dev/null | wc -l
echo "ucode/pnvm files"
ls ${INITRAMFS_DIR}/lib/firmware/i915/ 2>/dev/null | wc -l
echo "i915 files"

# Also add iwlwifi modules to initramfs so it can be loaded early
log "Adding iwlwifi modules to initramfs..."
IWL_SRC="${ROOTFS_DIR}/lib/modules/${KVER}/kernel/drivers/net/wireless/intel/iwlwifi"
IWL_DST="${INITRAMFS_DIR}/lib/modules/${KVER}/kernel/drivers/net/wireless/intel/iwlwifi"
mkdir -p "${IWL_DST}"
cp -r "${IWL_SRC}"/* "${IWL_DST}/"

# Also copy wireless stack dependencies
for mod_path in \
    "kernel/net/wireless/cfg80211.ko.xz" \
    "kernel/net/rfkill/rfkill.ko.xz" \
    "kernel/net/mac80211/mac80211.ko.xz" \
    "kernel/lib/crypto/libarc4.ko.xz"; do
    src="${ROOTFS_DIR}/lib/modules/${KVER}/${mod_path}"
    if [ -f "$src" ]; then
        dst="${INITRAMFS_DIR}/lib/modules/${KVER}/${mod_path}"
        mkdir -p "$(dirname "$dst")"
        cp "$src" "$dst"
    fi
done

# Regenerate modules.dep in initramfs
depmod -b "${INITRAMFS_DIR}" "${KVER}" 2>/dev/null || true

log "Total modules in initramfs:"
find "${INITRAMFS_DIR}/lib/modules/${KVER}" -name "*.ko*" 2>/dev/null | wc -l

# Rebuild initramfs cpio
log "Rebuilding initramfs cpio..."
cd "${INITRAMFS_DIR}"
find . | cpio -o -H newc 2>/dev/null | gzip -9 > "${BUILD_DIR}/initramfs.cpio.gz"
log "Initramfs: $(du -h "${BUILD_DIR}/initramfs.cpio.gz" | cut -f1)"

# Update disk image EFI partition
log "Updating EFI partition in disk image..."
IMAGE_FILE="${BUILD_DIR}/frost.img"
loop_dev=$(losetup --show -fP "${IMAGE_FILE}")
sleep 1
partprobe "${loop_dev}" 2>/dev/null || true
sleep 1

mkdir -p /tmp/efi-update
mount "${loop_dev}p1" /tmp/efi-update

cp "${BUILD_DIR}/initramfs.cpio.gz" /tmp/efi-update/boot/initramfs.img
log "Updated initramfs in EFI partition"
log "EFI initramfs size: $(du -h /tmp/efi-update/boot/initramfs.img | cut -f1)"

sync
umount /tmp/efi-update
rmdir /tmp/efi-update
losetup -d "${loop_dev}"

log "=== DONE - Initramfs updated with firmware ==="
