#!/bin/bash
# =============================================================================
# frOSt Deploy Script - Write frOSt image to USB drive
# =============================================================================
# Writes the built frOSt disk image to a physical USB drive and expands
# the persistence partition to use all remaining space.
#
# Usage (run as root inside WSL or native Linux):
#   sudo bash deploy.sh [--disk /dev/sdX] [--no-expand] [--yes]
#
# On Windows, use deploy-usb.ps1 instead (handles admin elevation and raw I/O).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE="/root/frost-build/frost.img"
TARGET_DEV=""
NO_EXPAND=0
AUTO_YES=0

# Colors
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
RESET='\033[0m'

log()  { echo -e "${CYAN}[frOSt-deploy]${RESET} $1"; }
ok()   { echo -e "${GREEN}[OK]${RESET} $1"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $1"; }
err()  { echo -e "${RED}[ERROR]${RESET} $1"; exit 1; }

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --disk)      TARGET_DEV="$2"; shift 2 ;;
        --image)     IMAGE="$2"; shift 2 ;;
        --no-expand) NO_EXPAND=1; shift ;;
        --yes|-y)    AUTO_YES=1; shift ;;
        -h|--help)
            echo "frOSt Deploy Script"
            echo ""
            echo "Usage: sudo bash deploy.sh [options]"
            echo ""
            echo "Options:"
            echo "  --disk /dev/sdX  Target device (e.g., /dev/sdb)"
            echo "  --image PATH     Path to frost.img (default: /root/frost-build/frost.img)"
            echo "  --no-expand      Don't expand persistence partition after writing"
            echo "  --yes, -y        Skip confirmation prompt"
            echo "  -h, --help       Show this help"
            echo ""
            echo "Must be run as root. On Windows, use deploy-usb.ps1 instead."
            exit 0
            ;;
        *) err "Unknown option: $1" ;;
    esac
done

# =============================================================================
# Step 1: Verify environment
# =============================================================================
log "Checking environment..."

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (sudo bash deploy.sh)"
fi

if [[ ! -f "$IMAGE" ]]; then
    err "Image not found: ${IMAGE}\nRun 'sudo bash build.sh' first."
fi

img_size=$(stat -c%s "$IMAGE")
img_mb=$(( img_size / 1048576 ))
ok "Image found: ${IMAGE} (${img_mb} MB)"

# =============================================================================
# Step 2: Find USB drive
# =============================================================================
if [[ -z "$TARGET_DEV" ]]; then
    log "Scanning for removable drives..."

    found=()
    for dev in /dev/sd?; do
        [[ -b "$dev" ]] || continue
        removable=$(cat "/sys/block/$(basename "$dev")/removable" 2>/dev/null || echo 0)
        if [[ "$removable" == "1" ]]; then
            dev_size=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)
            dev_gb=$(( dev_size / 1073741824 ))
            model=$(cat "/sys/block/$(basename "$dev")/device/model" 2>/dev/null || echo "Unknown")
            found+=("$dev")
            echo "  ${dev}: ${model} (${dev_gb} GB)"
        fi
    done

    if [[ ${#found[@]} -eq 0 ]]; then
        echo ""
        echo "No removable drives auto-detected."
        echo "Available block devices:"
        lsblk -d -o NAME,SIZE,TYPE,TRAN,MODEL 2>/dev/null || true
        echo ""
        read -rp "Enter device path (e.g., /dev/sdb): " TARGET_DEV
    elif [[ ${#found[@]} -eq 1 ]]; then
        TARGET_DEV="${found[0]}"
    else
        read -rp "Enter device path: " TARGET_DEV
    fi
fi

if [[ ! -b "$TARGET_DEV" ]]; then
    err "Device not found: ${TARGET_DEV}"
fi

target_size=$(blockdev --getsize64 "$TARGET_DEV" 2>/dev/null || echo 0)
target_gb=$(( target_size / 1073741824 ))

log "Target: ${TARGET_DEV} (${target_gb} GB)"

if [[ $img_size -gt $target_size ]]; then
    err "Image (${img_mb} MB) is larger than target (${target_gb} GB)"
fi

# =============================================================================
# Step 3: Confirm
# =============================================================================
echo ""
echo -e "${RED}════════════════════════════════════════════════════════${RESET}"
echo -e "${RED}  WARNING: ALL DATA ON ${TARGET_DEV} WILL BE DESTROYED${RESET}"
echo -e "${RED}════════════════════════════════════════════════════════${RESET}"
echo "  Target: ${TARGET_DEV} (${target_gb} GB)"
echo "  Source: ${IMAGE} (${img_mb} MB)"
echo ""

if [[ $AUTO_YES -eq 0 ]]; then
    read -rp "  Type 'yes' to continue: " confirm
    [[ "$confirm" == "yes" ]] || err "Aborted."
fi

# =============================================================================
# Step 4: Write image
# =============================================================================
log "Writing frOSt image to ${TARGET_DEV}..."
log "(${img_mb} MB - please wait)"
echo ""

dd if="$IMAGE" of="$TARGET_DEV" bs=4M status=progress conv=fsync

ok "Image written to ${TARGET_DEV}"

# =============================================================================
# Step 5: Fix GPT and expand persistence partition
# =============================================================================
if [[ $NO_EXPAND -eq 0 ]]; then
    log "Fixing GPT and expanding persistence partition..."

    # Fix GPT backup table
    sgdisk -e "$TARGET_DEV" 2>/dev/null || warn "sgdisk -e failed (non-critical)"

    # Re-read partition table
    partprobe "$TARGET_DEV" 2>/dev/null || true
    sleep 2

    PART3="${TARGET_DEV}3"
    if [[ -b "$PART3" ]]; then
        log "Expanding partition 3 to fill drive..."
        parted -s "$TARGET_DEV" resizepart 3 100% 2>/dev/null || {
            warn "parted resizepart failed, trying sgdisk..."
            START=$(sgdisk -i 3 "$TARGET_DEV" 2>/dev/null | grep 'First sector' | awk '{print $3}')
            if [[ -n "$START" ]]; then
                sgdisk -d 3 -n "3:${START}:0" -t 3:8300 -c 3:FROST_PERSIST "$TARGET_DEV" 2>/dev/null
                partprobe "$TARGET_DEV" 2>/dev/null
                sleep 1
            fi
        }

        log "Checking filesystem..."
        e2fsck -f -y "$PART3" 2>/dev/null || true

        log "Resizing filesystem..."
        resize2fs "$PART3" 2>/dev/null || true

        new_size=$(blockdev --getsize64 "$PART3" 2>/dev/null || echo 0)
        new_gb=$(( new_size / 1073741824 ))
        ok "Persistence partition: ${new_gb} GB"
    else
        warn "Partition 3 not found, skipping expansion"
    fi
fi

# =============================================================================
# Step 6: Done
# =============================================================================
sync

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}  frOSt deployed successfully!${RESET}"
echo -e "${GREEN}═══════════════════════════════════════════════════════${RESET}"
echo ""
echo "  To boot on real hardware:"
echo "    1. Insert USB into target machine"
echo "    2. Enter BIOS/UEFI boot menu (F12/F2/DEL)"
echo "    3. Select USB drive"
echo "    4. Choose 'frOSt Desktop' from GRUB menu"
echo ""
echo "  Default login: frost / frost"
echo ""
