#!/bin/bash
set -e

BUILD_DIR="/root/frost-build"
ROOTFS_DIR="${BUILD_DIR}/rootfs"
SRC_DIR="/mnt/c/Users/thoma/Documents/frOSt"
INITRAMFS_DIR="${BUILD_DIR}/initramfs"

log() { echo "[rebuild] $1"; }

KVER=$(ls ${ROOTFS_DIR}/lib/modules/ | sort -V | tail -1)
log "Using kernel: ${KVER}"

# =============================================
# Step 1: Quick pre-flight checks
# =============================================
log "Pre-flight checks..."
echo "  iwlwifi firmware (QuZ):"
ls ${ROOTFS_DIR}/lib/firmware/iwlwifi-QuZ-a0-hr-b0-*.ucode 2>/dev/null | wc -l
echo "  iwlwifi firmware (so):"
ls ${ROOTFS_DIR}/lib/firmware/iwlwifi-so-a0-hr-b0-*.ucode 2>/dev/null | wc -l
echo "  iwlwifi module:"
ls ${ROOTFS_DIR}/lib/modules/${KVER}/kernel/drivers/net/wireless/intel/iwlwifi/iwlwifi.ko* 2>/dev/null
echo "  dmesg service:"
ls ${ROOTFS_DIR}/etc/systemd/system/frost-dmesg-save*.service 2>/dev/null
echo "  NM config:"
grep managed ${ROOTFS_DIR}/etc/NetworkManager/NetworkManager.conf 2>/dev/null
echo "  WiFi profile:"
ls ${ROOTFS_DIR}/etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null

# =============================================
# Step 2: Rebuild initramfs (with latest modules)
# =============================================
log "Rebuilding initramfs..."

rm -rf "${INITRAMFS_DIR}"
mkdir -p "${INITRAMFS_DIR}"/{bin,sbin,usr/bin,usr/sbin,lib,lib64,dev,proc,sys,etc,run,tmp,frost}

# Copy busybox
cp /bin/busybox "${INITRAMFS_DIR}/bin/busybox" 2>/dev/null || \
    cp "$(command -v busybox)" "${INITRAMFS_DIR}/bin/busybox"
chmod 755 "${INITRAMFS_DIR}/bin/busybox"

# Create busybox symlinks
for cmd in sh ash mount umount mkdir cat echo ls cp mv rm ln chmod chown \
           mknod switch_root pivot_root sleep grep sed awk printf \
           mountpoint findfs blkid losetup readlink tr sort touch \
           rmdir basename dirname head tail cut mdev find uname wc; do
    ln -sf busybox "${INITRAMFS_DIR}/bin/${cmd}" 2>/dev/null || true
done
for cmd in modprobe insmod switch_root pivot_root blkid; do
    ln -sf ../bin/busybox "${INITRAMFS_DIR}/sbin/${cmd}" 2>/dev/null || true
done

# Copy early_init binary
cp "${BUILD_DIR}/early_init" "${INITRAMFS_DIR}/early_init"
chmod 755 "${INITRAMFS_DIR}/early_init"

# Copy init script
cp "${SRC_DIR}/initramfs/init" "${INITRAMFS_DIR}/init"
chmod 755 "${INITRAMFS_DIR}/init"

# Copy frost tools
cp "${SRC_DIR}/tools/frost-persist.py" "${INITRAMFS_DIR}/frost-persist.py"
cp "${SRC_DIR}/tools/frost-overlay.py" "${INITRAMFS_DIR}/frost-overlay.py"
cp "${SRC_DIR}/tools/frost-config.py"  "${INITRAMFS_DIR}/frost-config.py"

# Create device nodes
mknod -m 622 "${INITRAMFS_DIR}/dev/console" c 5 1 2>/dev/null || true
mknod -m 666 "${INITRAMFS_DIR}/dev/null"    c 1 3 2>/dev/null || true
mknod -m 666 "${INITRAMFS_DIR}/dev/zero"    c 1 5 2>/dev/null || true
mknod -m 666 "${INITRAMFS_DIR}/dev/tty"     c 5 0 2>/dev/null || true

# Copy kernel modules for new kernel
log "Copying kernel modules for ${KVER}..."

mod_src="${ROOTFS_DIR}/lib/modules/${KVER}"
mod_dst="${INITRAMFS_DIR}/lib/modules/${KVER}"
mkdir -p "${mod_dst}"

for subdir in drivers/ata drivers/scsi drivers/virtio drivers/block \
              drivers/usb/storage drivers/usb/host drivers/usb/core \
              drivers/hid \
              drivers/gpu/drm/bochs drivers/gpu/drm/virtio \
              drivers/gpu/drm/simpledrm drivers/gpu/drm/tiny \
              fs/overlayfs fs/squashfs fs/ext4 fs/fat fs/nls fs/jbd2 \
              block lib crypto arch/x86/crypto; do
    src_path="${mod_src}/kernel/${subdir}"
    if [ -d "$src_path" ]; then
        dst_path="${mod_dst}/kernel/${subdir}"
        mkdir -p "$dst_path"
        cp -r "${src_path}"/* "$dst_path/" 2>/dev/null || true
    fi
done

# Individual modules
for mod_pattern in "overlay.ko*" "squashfs.ko*" "loop.ko*" "virtio*.ko*" \
                   "libata.ko*" "ata_piix.ko*" "ahci.ko*" "sd_mod.ko*" \
                   "scsi_mod.ko*" "ata_generic.ko*" "libahci.ko*" \
                   "mbcache.ko*" "jbd2.ko*" "ext4.ko*" "crc*.ko*" \
                   "t10-pi.ko*" "crct10dif*.ko*" "crc-t10dif.ko*" \
                   "crc32c_generic.ko*" "crc64_rocksoft.ko*" \
                   "usb-common.ko*" "usbcore.ko*" "usb-storage.ko*" \
                   "xhci*.ko*" "ehci*.ko*" \
                   "hid.ko*" "usbhid.ko*" "hid-generic.ko*" \
                   "nls_*.ko*" "fat.ko*" "vfat.ko*" \
                   "drm.ko*" "drm_kms_helper.ko*" "bochs*.ko*" \
                   "virtio-gpu.ko*" "simpledrm.ko*"; do
    find "${mod_src}" -name "${mod_pattern}" 2>/dev/null | while read mod_file; do
        rel_path="${mod_file#${mod_src}/}"
        dest_dir="${mod_dst}/$(dirname "$rel_path")"
        mkdir -p "$dest_dir"
        cp "$mod_file" "$dest_dir/" 2>/dev/null || true
    done
done

# Copy modules.dep and related metadata
cp "${mod_src}/modules."* "${mod_dst}/" 2>/dev/null || true

# Regenerate modules.dep
depmod -b "${INITRAMFS_DIR}" "${KVER}" 2>/dev/null || true

mod_count=$(find "${mod_dst}" -name '*.ko*' 2>/dev/null | wc -l)
log "Copied ${mod_count} kernel modules"

# Create initramfs cpio
log "Creating initramfs cpio..."
cd "${INITRAMFS_DIR}"
find . | cpio -o -H newc 2>/dev/null | gzip -9 > "${BUILD_DIR}/initramfs.cpio.gz"
log "Initramfs: $(du -h "${BUILD_DIR}/initramfs.cpio.gz" | cut -f1)"

# =============================================
# Step 3: Rebuild squashfs
# =============================================
log "Cleaning apt cache..."
mount -t proc proc ${ROOTFS_DIR}/proc 2>/dev/null || true
chroot ${ROOTFS_DIR} /bin/bash -c "apt-get clean 2>/dev/null; rm -rf /var/cache/apt/archives/*.deb /tmp/* /var/tmp/*" 2>/dev/null || true
umount ${ROOTFS_DIR}/proc 2>/dev/null || true

log "Rebuilding squashfs..."
rm -f ${BUILD_DIR}/rootfs.squashfs
mksquashfs ${ROOTFS_DIR} ${BUILD_DIR}/rootfs.squashfs -comp xz -no-xattrs -quiet 2>/dev/null || \
mksquashfs ${ROOTFS_DIR} ${BUILD_DIR}/rootfs.squashfs -comp gzip -no-xattrs -quiet
log "Squashfs: $(du -h ${BUILD_DIR}/rootfs.squashfs | cut -f1)"

# =============================================
# Step 4: Build disk image
# =============================================
IMAGE_FILE="${BUILD_DIR}/frost.img"
IMAGE_SIZE_MB=4096
EFI_SIZE_MB=256
ROOT_SIZE_MB=2800

log "Creating disk image (${IMAGE_SIZE_MB}MB)..."
rm -f "${IMAGE_FILE}"
dd if=/dev/zero of="${IMAGE_FILE}" bs=1M count=0 seek="${IMAGE_SIZE_MB}" 2>/dev/null

parted -s "${IMAGE_FILE}" \
    mklabel gpt \
    mkpart "EFI" fat32 1MiB ${EFI_SIZE_MB}MiB \
    set 1 esp on \
    mkpart "FROST_ROOT" ext4 ${EFI_SIZE_MB}MiB $((EFI_SIZE_MB + ROOT_SIZE_MB))MiB \
    mkpart "FROST_PERSIST" ext4 $((EFI_SIZE_MB + ROOT_SIZE_MB))MiB 100%

loop_dev=$(losetup --show -fP "${IMAGE_FILE}")
log "Loop: ${loop_dev}"
sleep 1
partprobe "${loop_dev}" 2>/dev/null || true
sleep 1

mkfs.fat -F32 -n "EFI" "${loop_dev}p1"
mkfs.ext4 -L "FROST_ROOT" -q "${loop_dev}p2"
mkfs.ext4 -L "FROST_PERSIST" -q "${loop_dev}p3"

mnt="${BUILD_DIR}/mnt"
mkdir -p "${mnt}"/{efi,root,persist}

# EFI
mount "${loop_dev}p1" "${mnt}/efi"
mkdir -p "${mnt}/efi/EFI/BOOT" "${mnt}/efi/boot/grub"

vmlinuz="${ROOTFS_DIR}/boot/vmlinuz-${KVER}"
cp "${vmlinuz}" "${mnt}/efi/boot/vmlinuz"
cp "${BUILD_DIR}/initramfs.cpio.gz" "${mnt}/efi/boot/initramfs.img"

grub-mkimage \
    -o "${mnt}/efi/EFI/BOOT/BOOTX64.EFI" \
    -O x86_64-efi \
    -p /boot/grub \
    part_gpt part_msdos fat ext2 normal boot linux \
    configfile loopback chain efifwsetup efi_gop \
    efi_uga ls search search_label search_fs_uuid \
    search_fs_file gfxterm gfxterm_background \
    gfxterm_menu test all_video loadenv echo

grub-install \
    --target=i386-pc \
    --boot-directory="${mnt}/efi/boot" \
    --modules="part_gpt part_msdos fat ext2 normal boot linux configfile search search_label" \
    "${loop_dev}" 2>/dev/null || echo "BIOS GRUB failed (EFI only)"

# GRUB config - add iwlwifi debugging to kernel cmdline
cat > "${mnt}/efi/boot/grub/grub.cfg" << 'GRUBCFG'
set timeout=3
set default=0

serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1
terminal_input serial console
terminal_output serial console

set color_normal=cyan/black
set color_highlight=white/blue
set menu_color_normal=cyan/black
set menu_color_highlight=white/blue

menuentry "frOSt Desktop" {
    linux /boot/vmlinuz root=LABEL=FROST_ROOT ro quiet splash console=tty0 console=ttyS0,115200
    initrd /boot/initramfs.img
}

menuentry "frOSt Console (Text Mode)" {
    linux /boot/vmlinuz root=LABEL=FROST_ROOT ro quiet console=tty0 console=ttyS0,115200 systemd.unit=multi-user.target
    initrd /boot/initramfs.img
}

menuentry "frOSt (Debug - Verbose Boot)" {
    linux /boot/vmlinuz root=LABEL=FROST_ROOT ro debug loglevel=7 console=tty0 console=ttyS0,115200
    initrd /boot/initramfs.img
}

menuentry "frOSt (Recovery Mode)" {
    linux /boot/vmlinuz root=LABEL=FROST_ROOT ro single console=tty0 console=ttyS0,115200
    initrd /boot/initramfs.img
}
GRUBCFG

log "EFI done"

# Root
mount "${loop_dev}p2" "${mnt}/root"
cp "${BUILD_DIR}/rootfs.squashfs" "${mnt}/root/rootfs.squashfs"
log "Root: $(du -h "${mnt}/root/rootfs.squashfs" | cut -f1)"

# Persist
mount "${loop_dev}p3" "${mnt}/persist"
mkdir -p "${mnt}/persist/data"
cat > "${mnt}/persist/frost-persist.json" << 'PERSISTCFG'
{
  "version": 1,
  "persistent_paths": [
    "/etc/frost",
    "/home",
    "/var/lib/apt",
    "/var/cache/apt",
    "/etc/NetworkManager/system-connections",
    "/etc/hostname",
    "/etc/hosts"
  ],
  "persistent_packages": [],
  "persistent_services": [],
  "user_settings": {
    "auto_persist_home": true,
    "persist_logs": false,
    "persist_tmp": false
  }
}
PERSISTCFG

sync
umount "${mnt}/persist"
umount "${mnt}/root"
umount "${mnt}/efi"
losetup -d "${loop_dev}"

log "=== BUILD COMPLETE ==="
log "Kernel: ${KVER}"
log "Image: ${IMAGE_FILE} ($(du -h "${IMAGE_FILE}" | cut -f1))"
