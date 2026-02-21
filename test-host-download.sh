#!/bin/bash
# Test: download Debian bookworm packages from host using chroot's apt state
set -e

ROOTFS_DIR="/root/frost-build/rootfs"
BUILD_DIR="/root/frost-build"

echo "=== Phase 1: Create minimal chroot ==="
rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"
debootstrap --variant=minbase bookworm "$ROOTFS_DIR" http://deb.debian.org/debian 2>&1 | tail -3

echo "=== Phase 2: Configure sources.list ==="
cat > "${ROOTFS_DIR}/etc/apt/sources.list" << 'EOF'
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF

echo "=== Phase 3: Update package lists from host ==="
apt-get \
    -o Dir::Etc::SourceList="${ROOTFS_DIR}/etc/apt/sources.list" \
    -o Dir::Etc::SourceParts="/dev/null" \
    -o Dir::Cache="${ROOTFS_DIR}/var/cache/apt" \
    -o Dir::State="${ROOTFS_DIR}/var/lib/apt" \
    -o Dir::State::Status="${ROOTFS_DIR}/var/lib/dpkg/status" \
    -o APT::Architecture=amd64 \
    update 2>&1 | tail -10
echo "Update exit: $?"

echo "=== Phase 4: Download htop from host ==="
apt-get \
    -o Dir::Etc::SourceList="${ROOTFS_DIR}/etc/apt/sources.list" \
    -o Dir::Etc::SourceParts="/dev/null" \
    -o Dir::Cache="${ROOTFS_DIR}/var/cache/apt" \
    -o Dir::State="${ROOTFS_DIR}/var/lib/apt" \
    -o Dir::State::Status="${ROOTFS_DIR}/var/lib/dpkg/status" \
    -o APT::Architecture=amd64 \
    -d -y install htop 2>&1 | tail -10
echo "Download exit: $?"

echo "=== Phase 5: Check downloaded packages ==="
ls -la "${ROOTFS_DIR}/var/cache/apt/archives/" | head -10

echo "=== Phase 6: Install from cache in chroot ==="
mount --bind /dev "${ROOTFS_DIR}/dev" 2>/dev/null || true
mount -t proc proc "${ROOTFS_DIR}/proc" 2>/dev/null || true
chroot "${ROOTFS_DIR}" bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y htop 2>&1" | tail -10
echo "Chroot install exit: $?"
chroot "${ROOTFS_DIR}" htop --version
echo "=== SUCCESS ==="

umount -l "${ROOTFS_DIR}/proc" 2>/dev/null || true
umount -l "${ROOTFS_DIR}/dev" 2>/dev/null || true
