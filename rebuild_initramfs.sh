#!/bin/bash
# Quick rebuild of initramfs - shell-only init (no Python needed in initramfs)
set -e

BUILD_DIR="/root/frost-build"
INITRAMFS_DIR="${BUILD_DIR}/initramfs"
SRC_DIR="/mnt/c/Users/thoma/Documents/frOSt"

rm -rf "${INITRAMFS_DIR}"
mkdir -p "${INITRAMFS_DIR}"/{bin,sbin,usr/bin,usr/sbin,lib,lib64,dev,proc,sys,etc,run,tmp,frost}

# Busybox (provides shell + all utilities needed)
cp /bin/busybox "${INITRAMFS_DIR}/bin/busybox"
chmod 755 "${INITRAMFS_DIR}/bin/busybox"
for cmd in sh ash mount umount mkdir cat echo ls cp mv rm ln chmod chown \
           mknod switch_root pivot_root sleep grep sed awk printf \
           mountpoint findfs blkid losetup readlink tr sort touch \
           rmdir cd basename dirname head tail cut mdev; do
    ln -sf busybox "${INITRAMFS_DIR}/bin/${cmd}" 2>/dev/null || true
done
for cmd in modprobe insmod switch_root pivot_root blkid; do
    ln -sf ../bin/busybox "${INITRAMFS_DIR}/sbin/${cmd}" 2>/dev/null || true
done

# Early init binary (x86-64 asm)
cp "${BUILD_DIR}/early_init" "${INITRAMFS_DIR}/early_init"
chmod 755 "${INITRAMFS_DIR}/early_init"

# Init script (pure shell - no Python dependency)
cp "${SRC_DIR}/initramfs/init" "${INITRAMFS_DIR}/init"
chmod 755 "${INITRAMFS_DIR}/init"

# Python tools (copied into rootfs during pivot, used after boot)
cp "${SRC_DIR}/tools/frost-persist.py" "${INITRAMFS_DIR}/frost-persist.py"
cp "${SRC_DIR}/tools/frost-overlay.py" "${INITRAMFS_DIR}/frost-overlay.py"
cp "${SRC_DIR}/tools/frost-config.py"  "${INITRAMFS_DIR}/frost-config.py"

# Device nodes
mknod -m 622 "${INITRAMFS_DIR}/dev/console" c 5 1 2>/dev/null || true
mknod -m 666 "${INITRAMFS_DIR}/dev/null"    c 1 3 2>/dev/null || true
mknod -m 666 "${INITRAMFS_DIR}/dev/zero"    c 1 5 2>/dev/null || true
mknod -m 666 "${INITRAMFS_DIR}/dev/tty"     c 5 0 2>/dev/null || true

# Kernel modules - copy ALL relevant storage/filesystem/virtio modules
kver=$(ls "${BUILD_DIR}/rootfs/lib/modules/" | head -1)
if [ -n "$kver" ]; then
    mod_src="${BUILD_DIR}/rootfs/lib/modules/${kver}"
    mod_dst="${INITRAMFS_DIR}/lib/modules/${kver}"
    mkdir -p "${mod_dst}"

    # Copy entire driver subsystem directories that we need
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

    # Also copy key individual modules
    for mod_pattern in "overlay.ko*" "squashfs.ko*" "loop.ko*" "virtio*.ko*" \
                       "libata.ko*" "ata_piix.ko*" "ahci.ko*" "sd_mod.ko*" \
                       "scsi_mod.ko*" "ata_generic.ko*" "libahci.ko*" \
                       "mbcache.ko*" "jbd2.ko*" "ext4.ko*" "crc*.ko*" \
                       "drm.ko*" "drm_kms_helper.ko*" "bochs*.ko*" \
                       "virtio-gpu.ko*" "simpledrm.ko*"; do
        find "${mod_src}" -name "${mod_pattern}" 2>/dev/null | while read mod_file; do
            rel_path="${mod_file#${mod_src}/}"
            dest_dir="${mod_dst}/$(dirname "$rel_path")"
            mkdir -p "$dest_dir"
            cp "$mod_file" "$dest_dir/" 2>/dev/null || true
        done
    done

    cp "${mod_src}/modules."* "${mod_dst}/" 2>/dev/null || true
    depmod -b "${INITRAMFS_DIR}" "${kver}" 2>/dev/null || true
    echo "Kernel modules copied for ${kver}"

    # Show what we actually have
    echo "Module count: $(find ${mod_dst} -name '*.ko*' | wc -l)"
fi

# Create cpio archive
cd "${INITRAMFS_DIR}"
find . | cpio -o -H newc 2>/dev/null | gzip -9 > "${BUILD_DIR}/initramfs.cpio.gz"
echo "Initramfs rebuilt: $(du -h ${BUILD_DIR}/initramfs.cpio.gz | cut -f1)"

# Update the image EFI partition
kpartx -av "${BUILD_DIR}/frost.img" 2>&1
sleep 1

# Find the correct loop device
LOOP_P1=$(ls /dev/mapper/loop*p1 2>/dev/null | head -1)
if [ -z "$LOOP_P1" ]; then
    echo "ERROR: No loop partition found"
    exit 1
fi
echo "Using partition: $LOOP_P1"

mkdir -p "${BUILD_DIR}/mnt_efi"
mount "$LOOP_P1" "${BUILD_DIR}/mnt_efi"
cp "${BUILD_DIR}/initramfs.cpio.gz" "${BUILD_DIR}/mnt_efi/boot/initramfs.img"
echo "Updated initramfs in image: $(du -h ${BUILD_DIR}/mnt_efi/boot/initramfs.img | cut -f1)"
sync
umount "${BUILD_DIR}/mnt_efi"
kpartx -d "${BUILD_DIR}/frost.img"
echo "Image updated successfully"
