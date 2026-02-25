#!/bin/bash
set -e
ROOTFS=/root/frost-build/rootfs

echo "=== Checking frost user ==="
chroot ${ROOTFS} id frost
chroot ${ROOTFS} groups frost

echo ""
echo "=== Adding frost to video, audio, plugdev, netdev groups ==="
chroot ${ROOTFS} usermod -aG video,audio,plugdev,netdev frost 2>/dev/null || true

echo ""
echo "=== Verify ==="
chroot ${ROOTFS} id frost
chroot ${ROOTFS} groups frost

echo ""
echo "=== Total packages ==="
chroot ${ROOTFS} dpkg --get-selections | grep -c install

echo "DONE"
