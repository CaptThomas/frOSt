#!/bin/bash
set -e
ROOTFS=/root/frost-build/rootfs
KVER=$(ls ${ROOTFS}/lib/modules/ | sort -V | tail -1)

echo "=== Kernel version ==="
echo "${KVER}"

echo ""
echo "=== iwlwifi module firmware requirements ==="
IWLMOD="${ROOTFS}/lib/modules/${KVER}/kernel/drivers/net/wireless/intel/iwlwifi/iwlwifi.ko.xz"
if [ ! -f "$IWLMOD" ]; then
    IWLMOD="${ROOTFS}/lib/modules/${KVER}/kernel/drivers/net/wireless/intel/iwlwifi/iwlwifi.ko"
fi

if [ -f "$IWLMOD" ]; then
    apt-get install -y -qq xz-utils 2>/dev/null || true
    if [[ "$IWLMOD" == *.xz ]]; then
        xz -d -k "$IWLMOD" -c > /tmp/iwlwifi-check.ko 2>/dev/null
        MODFILE=/tmp/iwlwifi-check.ko
    else
        MODFILE="$IWLMOD"
    fi

    echo "All firmware entries from modinfo:"
    modinfo "$MODFILE" 2>/dev/null | grep "^firmware:" | sort
    echo ""
    echo "QuZ-related firmware entries:"
    modinfo "$MODFILE" 2>/dev/null | grep "^firmware:" | grep -i "qu" || echo "(none)"
    echo ""
    echo "so-related firmware entries (AX201 may use 'so' family in newer kernels):"
    modinfo "$MODFILE" 2>/dev/null | grep "^firmware:" | grep -i "\-so" || echo "(none)"
    echo ""
    echo "Module version info:"
    modinfo "$MODFILE" 2>/dev/null | grep -E "^(version|vermagic|description|srcversion):"

    echo ""
    echo "=== Config names embedded in module ==="
    strings "$MODFILE" | grep -E "^iwlwifi-" | sort -u

    echo ""
    echo "=== API version strings in module ==="
    strings "$MODFILE" | grep -iE "api|ucode.*max|maximum.*version|fw_api" | head -30

    rm -f /tmp/iwlwifi-check.ko
else
    echo "iwlwifi module not found"
    find ${ROOTFS}/lib/modules/${KVER} -name "iwlwifi*" 2>/dev/null
fi

echo ""
echo "=== QuZ firmware files in rootfs ==="
ls -la ${ROOTFS}/lib/firmware/iwlwifi-QuZ* 2>/dev/null || echo "(none)"

echo ""
echo "=== 'so' family firmware files in rootfs ==="
ls -la ${ROOTFS}/lib/firmware/iwlwifi-so* 2>/dev/null || echo "(none)"

echo ""
echo "=== All iwlwifi ucode files with sizes ==="
ls -la ${ROOTFS}/lib/firmware/iwlwifi-*.ucode 2>/dev/null | awk '{print $5, $9}' | sort -t- -k2

echo ""
echo "=== PNVM files ==="
ls -la ${ROOTFS}/lib/firmware/iwlwifi*.pnvm 2>/dev/null || echo "(none)"
ls -la ${ROOTFS}/lib/firmware/intel/ibt* 2>/dev/null | head -3 || true

echo ""
echo "=== firmware-iwlwifi package version ==="
dpkg --admindir=${ROOTFS}/var/lib/dpkg -l firmware-iwlwifi 2>/dev/null | tail -2

echo ""
echo "=== kernel packages ==="
dpkg --admindir=${ROOTFS}/var/lib/dpkg -l 'linux-image-*' 2>/dev/null | grep '^ii'

echo ""
echo "=== Check firmware files the module requests that are MISSING ==="
if [ -f "$IWLMOD" ]; then
    if [[ "$IWLMOD" == *.xz ]]; then
        xz -d -k "$IWLMOD" -c > /tmp/iwlwifi-check.ko 2>/dev/null
        MODFILE=/tmp/iwlwifi-check.ko
    else
        MODFILE="$IWLMOD"
    fi

    echo "Missing firmware (requested by module but not in rootfs):"
    modinfo "$MODFILE" 2>/dev/null | grep "^firmware:" | while read line; do
        fw=$(echo "$line" | awk '{print $2}')
        if [ ! -f "${ROOTFS}/lib/firmware/${fw}" ]; then
            echo "  MISSING: ${fw}"
        fi
    done

    echo ""
    echo "Present firmware (requested by module AND in rootfs):"
    modinfo "$MODFILE" 2>/dev/null | grep "^firmware:" | while read line; do
        fw=$(echo "$line" | awk '{print $2}')
        if [ -f "${ROOTFS}/lib/firmware/${fw}" ]; then
            echo "  OK: ${fw}"
        fi
    done

    rm -f /tmp/iwlwifi-check.ko
fi

echo ""
echo "=== DONE ==="
