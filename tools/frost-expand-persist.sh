#!/bin/bash
# =============================================================================
# frOSt Auto-Expand Persistence Partition
# =============================================================================
# Runs on boot to expand the persistence partition (partition 3) to fill
# all available disk space. Handles GPT backup table relocation.
# Idempotent - safe to run on every boot.
# =============================================================================

set -e

LOG_TAG="frost-expand"
log() { echo "[$LOG_TAG] $1"; logger -t "$LOG_TAG" "$1" 2>/dev/null || true; }

# Find the boot disk by looking at where the root squashfs lives
find_boot_disk() {
    # Check /proc/cmdline for root device hints
    local root_dev=""

    # Try to find the FROST_ROOT partition
    root_dev=$(blkid -L FROST_ROOT 2>/dev/null | head -1) || true

    if [[ -z "$root_dev" ]]; then
        # Look at mounted filesystems for clues
        root_dev=$(awk '/frost/ {print $1; exit}' /proc/mounts 2>/dev/null) || true
    fi

    if [[ -z "$root_dev" ]]; then
        # Scan for our partition layout
        for dev in /dev/sda /dev/vda /dev/nvme0n1 /dev/mmcblk0; do
            if [[ -b "${dev}2" ]] || [[ -b "${dev}p2" ]]; then
                local part2="${dev}2"
                [[ -b "${dev}p2" ]] && part2="${dev}p2"
                local label=$(blkid -s LABEL -o value "$part2" 2>/dev/null) || true
                if [[ "$label" == "FROST_ROOT" ]]; then
                    root_dev="$part2"
                    break
                fi
            fi
        done
    fi

    if [[ -z "$root_dev" ]]; then
        return 1
    fi

    # Strip partition number to get the disk device
    echo "$root_dev" | sed 's/p\?[0-9]*$//'
}

# Get partition 3 device path from disk device
get_part3() {
    local disk="$1"
    if [[ "$disk" == *"nvme"* ]] || [[ "$disk" == *"mmcblk"* ]]; then
        echo "${disk}p3"
    else
        echo "${disk}3"
    fi
}

main() {
    log "Checking if persistence partition needs expansion..."

    local disk
    disk=$(find_boot_disk) || {
        log "Could not determine boot disk, skipping"
        exit 0
    }

    local part3
    part3=$(get_part3 "$disk")

    if [[ ! -b "$part3" ]]; then
        log "Partition 3 ($part3) not found, skipping"
        exit 0
    fi

    # Get disk size and partition 3 end
    local disk_size
    disk_size=$(blockdev --getsize64 "$disk" 2>/dev/null) || {
        log "Cannot read disk size, skipping"
        exit 0
    }

    local part3_size
    part3_size=$(blockdev --getsize64 "$part3" 2>/dev/null) || {
        log "Cannot read partition size, skipping"
        exit 0
    }

    local disk_gb=$(( disk_size / 1073741824 ))
    local part3_gb=$(( part3_size / 1073741824 ))

    # Calculate free space after partition 3
    # Get partition 3 end sector and disk end sector
    local part3_end_bytes=$(( part3_size ))
    local free_bytes=$(( disk_size - part3_size - 3 * 1073741824 ))  # rough estimate (subtract ~3GB for partitions 1+2)

    # Only expand if there's more than 500MB of unallocated space
    if [[ $free_bytes -lt 524288000 ]]; then
        log "Partition 3 already fills disk ($part3_gb GB / $disk_gb GB disk), no expansion needed"
        exit 0
    fi

    log "Disk: $disk ($disk_gb GB), Persistence: $part3 ($part3_gb GB)"
    log "Free space detected, expanding partition..."

    # Step 1: Fix GPT backup table (move to end of disk)
    if command -v sgdisk >/dev/null 2>&1; then
        log "Relocating GPT backup table to end of disk..."
        sgdisk -e "$disk" 2>&1 | while read -r line; do log "  sgdisk: $line"; done || {
            log "sgdisk -e failed (non-critical, continuing)"
        }
    fi

    # Step 2: Expand partition 3 to fill disk
    if command -v parted >/dev/null 2>&1; then
        log "Expanding partition 3..."
        parted -s "$disk" resizepart 3 100% 2>&1 | while read -r line; do log "  parted: $line"; done || {
            log "parted resizepart failed"
            exit 0
        }
    elif command -v sgdisk >/dev/null 2>&1; then
        log "Expanding partition 3 via sgdisk..."
        local start
        start=$(sgdisk -i 3 "$disk" 2>/dev/null | grep 'First sector' | awk '{print $3}') || true
        if [[ -n "$start" ]]; then
            sgdisk -d 3 -n "3:${start}:0" -t 3:8300 -c 3:FROST_PERSIST "$disk" 2>&1 || {
                log "sgdisk partition resize failed"
                exit 0
            }
        fi
    else
        log "No partition tool available (need parted or sgdisk), skipping"
        exit 0
    fi

    # Re-read partition table
    if command -v partprobe >/dev/null 2>&1; then
        partprobe "$disk" 2>/dev/null || true
    fi
    sleep 2

    # Step 3: Expand ext4 filesystem
    local new_part3_size
    new_part3_size=$(blockdev --getsize64 "$part3" 2>/dev/null) || true

    if [[ -n "$new_part3_size" ]] && [[ $new_part3_size -gt $part3_size ]]; then
        log "Partition expanded, resizing filesystem..."

        # Unmount if mounted (will be remounted by system)
        local was_mounted=0
        if mountpoint -q /frost/persist 2>/dev/null; then
            umount /frost/persist 2>/dev/null || true
            was_mounted=1
        fi

        # Check and resize filesystem
        e2fsck -f -y "$part3" 2>&1 | tail -3 | while read -r line; do log "  e2fsck: $line"; done || true
        resize2fs "$part3" 2>&1 | while read -r line; do log "  resize2fs: $line"; done || {
            log "resize2fs failed"
        }

        # Remount if it was mounted
        if [[ $was_mounted -eq 1 ]]; then
            mount "$part3" /frost/persist 2>/dev/null || true
        fi

        local final_size
        final_size=$(blockdev --getsize64 "$part3" 2>/dev/null || echo 0)
        local final_gb=$(( final_size / 1073741824 ))
        log "Persistence partition expanded to $final_gb GB"
    else
        log "Partition size unchanged, filesystem resize skipped"
    fi

    log "Expansion complete"
}

main "$@"
