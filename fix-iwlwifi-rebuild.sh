#!/bin/bash
set -e
BUILD_DIR="/root/frost-build"
ROOTFS="${BUILD_DIR}/rootfs"
INITRAMFS_DIR="${BUILD_DIR}/initramfs"
KVER=$(ls ${ROOTFS}/lib/modules/ | sort -V | tail -1)

log() { echo "[fix-rebuild] $1"; }

# ============================================================
# FIX 1: iwlwifi modprobe config - THE ROOT CAUSE
# ============================================================
log "=== FIX 1: Fixing iwlwifi modprobe config ==="
log "Current iwlwifi.conf:"
cat "${ROOTFS}/etc/modprobe.d/iwlwifi.conf" 2>/dev/null || echo "(not found)"

# Fix the config - enable_ini expects integer 0, not character 'N'
printf '# frOSt iwlwifi configuration\n# enable_ini=0 disables internal debug tracing (must be integer, NOT N)\noptions iwlwifi enable_ini=0\noptions iwlmvm power_scheme=1\n' > "${ROOTFS}/etc/modprobe.d/iwlwifi.conf"

log "Fixed iwlwifi.conf:"
cat "${ROOTFS}/etc/modprobe.d/iwlwifi.conf"

# ============================================================
# FIX 2: Install pciutils
# ============================================================
log "=== FIX 2: Installing pciutils ==="
chroot "${ROOTFS}" apt-get install -y pciutils 2>&1 | tail -5

# ============================================================
# FIX 3: Verify iwlwifi modules exist
# ============================================================
log "=== FIX 3: Verify iwlwifi modules ==="
log "Kernel version: ${KVER}"
IWL_DIR="${ROOTFS}/lib/modules/${KVER}/kernel/drivers/net/wireless/intel/iwlwifi"
log "iwlwifi modules:"
find "${IWL_DIR}" -name "*.ko*" 2>/dev/null | while read f; do echo "  $(basename $f)"; done

log "iwlwifi firmware files (AX201):"
ls ${ROOTFS}/lib/firmware/iwlwifi-QuZ-a0-hr-b0* ${ROOTFS}/lib/firmware/iwlwifi-so-a0-hr-b0* 2>/dev/null | while read f; do echo "  $(basename $f)"; done

# ============================================================
# FIX 4: Add iwlwifi to /etc/modules-load.d for belt-and-suspenders
# ============================================================
log "=== FIX 4: Add iwlwifi to modules-load.d ==="
printf 'rfkill\ncfg80211\nmac80211\niwlwifi\niwlmvm\n' > "${ROOTFS}/etc/modules-load.d/iwlwifi.conf"
log "Created /etc/modules-load.d/iwlwifi.conf"

# ============================================================
# FIX 5: Verify desktop fixes are still in place
# ============================================================
log "=== FIX 5: Verify desktop fixes ==="
log "DPMS config:"
cat "${ROOTFS}/etc/X11/xorg.conf.d/10-no-dpms.conf" 2>/dev/null | head -5 || echo "MISSING!"
log "Intel GPU config:"
cat "${ROOTFS}/etc/X11/xorg.conf.d/20-intel.conf" 2>/dev/null | head -5 || echo "MISSING!"
log "xscreensaver autostart:"
if [ -f "${ROOTFS}/etc/xdg/autostart/xscreensaver.desktop" ]; then
    echo "STILL EXISTS - removing"
    rm -f "${ROOTFS}/etc/xdg/autostart/xscreensaver.desktop"
else
    echo "Already removed - GOOD"
fi
log "Power manager config:"
[ -f "${ROOTFS}/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-power-manager.xml" ] && echo "EXISTS - GOOD" || echo "MISSING!"

# ============================================================
# FIX 6: Rebuild squashfs
# ============================================================
log "=== FIX 6: Rebuilding squashfs ==="
mksquashfs "${ROOTFS}" "${BUILD_DIR}/rootfs.squashfs" \
    -comp xz -b 262144 -Xbcj x86 -noappend 2>&1 | tail -3
log "Squashfs size: $(du -h ${BUILD_DIR}/rootfs.squashfs | cut -f1)"

# ============================================================
# FIX 7: Rebuild initramfs with firmware
# ============================================================
log "=== FIX 7: Rebuilding initramfs with firmware ==="

# Add iwlwifi firmware to initramfs
mkdir -p "${INITRAMFS_DIR}/lib/firmware"
for prefix in QuZ-a0-hr-b0 QuZ-a0-jf-b0 Qu-b0-hr-b0 Qu-b0-jf-b0 Qu-c0-hr-b0 Qu-c0-jf-b0 so-a0-hr-b0 so-a0-gf-a0 so-a0-jf-b0 cc-a0; do
    for f in ${ROOTFS}/lib/firmware/iwlwifi-${prefix}*.ucode; do
        [ -f "$f" ] && cp "$f" "${INITRAMFS_DIR}/lib/firmware/"
    done
done
# PNVM files
for f in ${ROOTFS}/lib/firmware/iwlwifi-*.pnvm; do
    [ -f "$f" ] && cp "$f" "${INITRAMFS_DIR}/lib/firmware/"
done

# Tiger Lake i915 firmware (hardware is TGL, not ICL)
mkdir -p "${INITRAMFS_DIR}/lib/firmware/i915"
for f in ${ROOTFS}/lib/firmware/i915/tgl_*.bin ${ROOTFS}/lib/firmware/i915/icl_*.bin; do
    [ -f "$f" ] && cp "$f" "${INITRAMFS_DIR}/lib/firmware/i915/"
done

log "Firmware in initramfs:"
echo "  $(ls ${INITRAMFS_DIR}/lib/firmware/iwlwifi-* 2>/dev/null | wc -l) ucode/pnvm files"
echo "  $(ls ${INITRAMFS_DIR}/lib/firmware/i915/ 2>/dev/null | wc -l) i915 files"

# Add iwlwifi kernel modules to initramfs
IWL_SRC="${ROOTFS}/lib/modules/${KVER}/kernel/drivers/net/wireless/intel/iwlwifi"
IWL_DST="${INITRAMFS_DIR}/lib/modules/${KVER}/kernel/drivers/net/wireless/intel/iwlwifi"
mkdir -p "${IWL_DST}"
cp -r "${IWL_SRC}"/* "${IWL_DST}/"

# Copy wireless stack dependencies
for mod_path in \
    "kernel/net/wireless/cfg80211.ko.xz" \
    "kernel/net/rfkill/rfkill.ko.xz" \
    "kernel/net/mac80211/mac80211.ko.xz" \
    "kernel/lib/crypto/libarc4.ko.xz"; do
    src="${ROOTFS}/lib/modules/${KVER}/${mod_path}"
    if [ -f "$src" ]; then
        dst="${INITRAMFS_DIR}/lib/modules/${KVER}/${mod_path}"
        mkdir -p "$(dirname "$dst")"
        cp "$src" "$dst"
    fi
done

# Regenerate modules.dep for initramfs
depmod -b "${INITRAMFS_DIR}" "${KVER}" 2>/dev/null || true

# Rebuild initramfs cpio
cd "${INITRAMFS_DIR}"
find . | cpio -o -H newc 2>/dev/null | gzip -9 > "${BUILD_DIR}/initramfs.cpio.gz"
log "Initramfs size: $(du -h ${BUILD_DIR}/initramfs.cpio.gz | cut -f1)"

# ============================================================
# FIX 8: Update disk image
# ============================================================
log "=== FIX 8: Updating disk image ==="
IMAGE_FILE="${BUILD_DIR}/frost.img"
loop_dev=$(losetup --show -fP "${IMAGE_FILE}")
sleep 1
partprobe "${loop_dev}" 2>/dev/null || true
sleep 1

# Mount EFI partition
mkdir -p /tmp/efi-update
mount "${loop_dev}p1" /tmp/efi-update

# Update squashfs on rootfs partition
mkdir -p /tmp/root-update
mount "${loop_dev}p2" /tmp/root-update
cp "${BUILD_DIR}/rootfs.squashfs" /tmp/root-update/rootfs.squashfs
log "Updated squashfs in rootfs partition"
log "Rootfs partition usage:"
df -h /tmp/root-update | tail -1

# Update initramfs in EFI
cp "${BUILD_DIR}/initramfs.cpio.gz" /tmp/efi-update/boot/initramfs.img
log "Updated initramfs in EFI partition"

# Show what's in EFI
log "EFI boot contents:"
ls -la /tmp/efi-update/boot/
log "EFI partition usage:"
df -h /tmp/efi-update | tail -1

sync
umount /tmp/root-update
rmdir /tmp/root-update
umount /tmp/efi-update
rmdir /tmp/efi-update
losetup -d "${loop_dev}"

log "============================================"
log "=== ALL FIXES APPLIED AND IMAGE UPDATED ==="
log "============================================"
log "Key fix: iwlwifi enable_ini=N changed to enable_ini=0"
log "Image ready for deployment: ${IMAGE_FILE}"
