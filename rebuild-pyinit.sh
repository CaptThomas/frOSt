#!/bin/bash
# =============================================================================
# frOSt: Rebuild initramfs with shell+Python hybrid init
# =============================================================================
# The init chain is:
#   /init (shell shim) -> /early_init (asm) -> /frost_init.py (run by squashfs Python)
#
# No Python is bundled in the initramfs. The shell handles everything up to
# mounting the squashfs, then frost_init.py runs using Python from the squashfs.
# =============================================================================

set -euo pipefail

C='\033[1;36m'
G='\033[1;32m'
R='\033[1;31m'
N='\033[0m'

log() { echo -e "${C}[frOSt]${N} $1"; }
ok()  { echo -e "${G}[OK]${N} $1"; }
err() { echo -e "${R}[ERROR]${N} $1"; exit 1; }

SRC=/mnt/c/Users/thoma/Documents/frOSt
BUILD=/root/frost-pyinit-build
IMG=${SRC}/frost.img
INITRAMFS=${BUILD}/initramfs

[[ $EUID -eq 0 ]] || err "Must run as root"
[[ -f "${IMG}" ]] || err "frost.img not found"

cleanup() {
    umount ${BUILD}/sqfs 2>/dev/null || true
    umount ${BUILD}/root 2>/dev/null || true
    umount ${BUILD}/efi 2>/dev/null || true
    local l
    l=$(losetup -j "${IMG}" 2>/dev/null | awk -F: 'NR==1{print $1}') || true
    [ -n "$l" ] && losetup -d "$l" 2>/dev/null || true
}
trap cleanup EXIT

rm -rf "${BUILD}"
mkdir -p "${BUILD}"

# ── Mount image to get rootfs ──
log "Mounting image..."
losetup -D 2>/dev/null || true
losetup -fP "${IMG}"
sleep 1
LOOP=$(losetup -j "${IMG}" 2>/dev/null | awk -F: 'NR==1{print $1}') || true
[ -z "$LOOP" ] && err "losetup failed"
sleep 1; partprobe "${LOOP}" 2>/dev/null || true; sleep 1
log "Loop: ${LOOP}"

mkdir -p ${BUILD}/{root,sqfs,efi}
mount "${LOOP}p2" ${BUILD}/root
mount -t squashfs -o ro,loop ${BUILD}/root/rootfs.squashfs ${BUILD}/sqfs

ROOTFS=${BUILD}/sqfs
KVER=$(ls ${ROOTFS}/lib/modules/ | head -1)
log "Kernel: ${KVER}"

# ── Build assembly ──
log "Assembling early_init..."
command -v nasm >/dev/null 2>&1 || apt-get install -y -qq nasm
nasm -f elf64 -o ${BUILD}/early_init.o ${SRC}/boot/asm/early_init.asm
ld -o ${BUILD}/early_init ${BUILD}/early_init.o --oformat=elf64-x86-64 -e _start --static
strip --strip-all ${BUILD}/early_init 2>/dev/null || true
ok "early_init: $(stat -c%s ${BUILD}/early_init) bytes"

# ── Build initramfs ──
log "Building initramfs..."
mkdir -p ${INITRAMFS}/{bin,sbin,usr/bin,usr/sbin,lib,lib64,dev,proc,sys,etc,run,tmp,frost}

# Busybox - prefer static from rootfs, or use system busybox + dynamic linker
if [[ -f "${ROOTFS}/bin/busybox" ]]; then
    log "Using busybox from rootfs"
    cp "${ROOTFS}/bin/busybox" ${INITRAMFS}/bin/busybox
    # Check if it's dynamic and copy linker if needed
    if ldd "${ROOTFS}/bin/busybox" 2>/dev/null | grep -q "ld-"; then
        log "Copying dynamic linker for busybox"
        # Debian uses /lib64/ld-linux-x86-64.so.2 or /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2
        for linker in "${ROOTFS}/lib64/ld-linux-x86-64.so.2" "${ROOTFS}/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2"; do
            if [[ -f "$linker" ]]; then
                mkdir -p ${INITRAMFS}/$(dirname "${linker#${ROOTFS}}")
                cp "$linker" ${INITRAMFS}/"${linker#${ROOTFS}}"
            fi
        done
        # Copy libc and other deps
        for libdir in "${ROOTFS}/lib" "${ROOTFS}/lib64" "${ROOTFS}/lib/x86_64-linux-gnu"; do
            [[ -d "$libdir" ]] && cp -r "$libdir" ${INITRAMFS}/ 2>/dev/null || true
        done
    fi
else
    log "Using system busybox"
    BB=$(command -v busybox || echo /bin/busybox)
    cp "$BB" ${INITRAMFS}/bin/busybox
    # Copy musl dynamic linker if busybox is dynamic
    if ldd "$BB" 2>/dev/null | grep -q "ld-musl"; then
        log "Copying musl linker for busybox"
        mkdir -p ${INITRAMFS}/lib
        cp /lib/ld-musl-x86_64.so.1 ${INITRAMFS}/lib/ 2>/dev/null || true
    fi
fi
chmod 755 ${INITRAMFS}/bin/busybox
ok "Busybox installed"

for cmd in sh ash mount umount mkdir cat echo ls cp mv rm ln chmod chown \
           mknod switch_root pivot_root sleep grep sed awk printf \
           mountpoint findfs blkid losetup readlink tr sort touch \
           rmdir basename dirname head tail cut mdev find uname wc dmesg; do
    ln -sf busybox ${INITRAMFS}/bin/${cmd} 2>/dev/null || true
done
for cmd in modprobe insmod switch_root pivot_root blkid; do
    ln -sf ../bin/busybox ${INITRAMFS}/sbin/${cmd} 2>/dev/null || true
done

# Assembly early_init
cp ${BUILD}/early_init ${INITRAMFS}/early_init
chmod 755 ${INITRAMFS}/early_init

# Shell init shim (the /init the kernel executes)
cp ${SRC}/initramfs/init ${INITRAMFS}/init
chmod 755 ${INITRAMFS}/init

# Python init script (run by squashfs Python after squashfs is mounted)
cp ${SRC}/initramfs/frost_init.py ${INITRAMFS}/frost_init.py

# Python tools (copied into merged root during boot)
cp ${SRC}/tools/frost-persist.py ${INITRAMFS}/frost-persist.py
cp ${SRC}/tools/frost-overlay.py ${INITRAMFS}/frost-overlay.py
cp ${SRC}/tools/frost-config.py  ${INITRAMFS}/frost-config.py

# Device nodes
mknod -m 622 ${INITRAMFS}/dev/console c 5 1 2>/dev/null || true
mknod -m 666 ${INITRAMFS}/dev/null    c 1 3 2>/dev/null || true
mknod -m 666 ${INITRAMFS}/dev/zero    c 1 5 2>/dev/null || true
mknod -m 666 ${INITRAMFS}/dev/tty     c 5 0 2>/dev/null || true

# Kernel modules
log "Copying kernel modules..."
MOD_SRC=${ROOTFS}/lib/modules/${KVER}
MOD_DST=${INITRAMFS}/lib/modules/${KVER}
mkdir -p ${MOD_DST}

for subdir in drivers/ata drivers/scsi drivers/virtio drivers/block \
              drivers/usb/common drivers/usb/storage drivers/usb/host drivers/usb/core \
              drivers/hid \
              drivers/gpu/drm/bochs drivers/gpu/drm/virtio \
              drivers/gpu/drm/simpledrm drivers/gpu/drm/tiny \
              fs/overlayfs fs/squashfs fs/ext4 fs/fat fs/nls fs/jbd2 \
              block lib crypto arch/x86/crypto; do
    if [[ -d "${MOD_SRC}/kernel/${subdir}" ]]; then
        mkdir -p "${MOD_DST}/kernel/${subdir}"
        cp -r "${MOD_SRC}/kernel/${subdir}"/* "${MOD_DST}/kernel/${subdir}/" 2>/dev/null || true
    fi
done

for pat in "overlay.ko*" "squashfs.ko*" "loop.ko*" "virtio*.ko*" \
           "libata.ko*" "ahci.ko*" "sd_mod.ko*" "scsi_mod.ko*" \
           "ext4.ko*" "jbd2.ko*" "crc*.ko*" "mbcache.ko*" \
           "drm.ko*" "drm_kms_helper.ko*" "bochs.ko*"; do
    find "${MOD_SRC}" -name "${pat}" 2>/dev/null | while read -r f; do
        rel="${f#${MOD_SRC}/}"
        d="${MOD_DST}/$(dirname "$rel")"
        mkdir -p "$d"
        cp "$f" "$d/" 2>/dev/null || true
    done
done

cp "${MOD_SRC}/modules."* "${MOD_DST}/" 2>/dev/null || true
depmod -b ${INITRAMFS} ${KVER} 2>/dev/null || true
MODCOUNT=$(find ${MOD_DST} -name '*.ko*' 2>/dev/null | wc -l)
ok "${MODCOUNT} kernel modules"

# Pack cpio
log "Packing initramfs..."
cd ${INITRAMFS}
find . | cpio -o -H newc 2>/dev/null | gzip -9 > ${BUILD}/initramfs.cpio.gz
ok "Initramfs: $(du -h ${BUILD}/initramfs.cpio.gz | cut -f1)"

# ── Inject into image ──
log "Injecting into image..."
umount ${BUILD}/sqfs 2>/dev/null || true
umount ${BUILD}/root 2>/dev/null || true

mount "${LOOP}p1" ${BUILD}/efi
log "Old initramfs: $(du -h ${BUILD}/efi/boot/initramfs.img | cut -f1)"
cp ${BUILD}/initramfs.cpio.gz ${BUILD}/efi/boot/initramfs.img
log "New initramfs: $(du -h ${BUILD}/efi/boot/initramfs.img | cut -f1)"
sync
umount ${BUILD}/efi

echo ""
echo -e "${G}═══════════════════════════════════════════${N}"
echo -e "${G} frOSt init rebuilt!${N}"
echo -e "${G} Boot chain: asm -> shell shim -> python${N}"
echo -e "${G}═══════════════════════════════════════════${N}"
