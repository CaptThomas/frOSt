#!/usr/bin/python3
"""
frOSt USB Watchdog - Detects USB removal and triggers clean shutdown.

Monitors the boot device (FROST_ROOT partition) for disappearance.
When the USB drive is physically removed, initiates an immediate
but clean shutdown to prevent data loss.

Runs as a systemd service: frost-usb-watchdog.service
"""

import os
import sys
import time
import subprocess
import signal

POLL_INTERVAL = 1.0    # seconds between checks
LABEL = "FROST_ROOT"

def find_boot_device():
    """Find the block device backing FROST_ROOT."""
    # Method 1: findfs
    try:
        result = subprocess.run(
            ["findfs", f"LABEL={LABEL}"],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    except Exception:
        pass

    # Method 2: /dev/disk/by-label
    label_path = f"/dev/disk/by-label/{LABEL}"
    if os.path.exists(label_path):
        try:
            return os.path.realpath(label_path)
        except Exception:
            pass

    # Method 3: Check mount table
    try:
        with open("/proc/mounts", "r") as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 2 and "/frost" in parts[1]:
                    return parts[0]
    except Exception:
        pass

    return None

def get_parent_disk(dev_path):
    """Get the parent disk device from a partition device path.
    e.g., /dev/sda2 -> /dev/sda, /dev/nvme0n1p2 -> /dev/nvme0n1
    """
    basename = os.path.basename(dev_path)
    # Handle nvme/mmcblk style: nvme0n1p2 -> nvme0n1
    if "nvme" in basename or "mmcblk" in basename:
        idx = basename.rfind("p")
        if idx > 0 and basename[idx+1:].isdigit():
            return f"/dev/{basename[:idx]}"
    # Handle sd/vd/hd style: sda2 -> sda
    for i in range(len(basename) - 1, -1, -1):
        if not basename[i].isdigit():
            return f"/dev/{basename[:i+1]}"
    return dev_path

def device_present(dev_path):
    """Check if a block device is still present."""
    # Check if the device node exists
    if not os.path.exists(dev_path):
        return False
    # Check if the parent disk is still in /sys/block
    parent = get_parent_disk(dev_path)
    parent_name = os.path.basename(parent)
    if not os.path.exists(f"/sys/block/{parent_name}"):
        return False
    return True

def initiate_shutdown():
    """Perform a clean immediate shutdown."""
    try:
        # Sync filesystems first
        os.system("sync")
        # Log the event
        os.system(
            'logger -t frost-usb-watchdog '
            '"USB boot device removed - initiating shutdown"'
        )
        # Immediate poweroff
        os.execv("/usr/bin/systemctl", ["systemctl", "poweroff", "--force"])
    except Exception:
        # Fallback: direct reboot syscall with POWER_OFF
        os.system("poweroff -f")

def main():
    # Find the boot device
    boot_dev = find_boot_device()
    if not boot_dev:
        print("frost-usb-watchdog: Cannot determine boot device, exiting",
              file=sys.stderr)
        sys.exit(1)

    parent_disk = get_parent_disk(boot_dev)
    parent_name = os.path.basename(parent_disk)

    print(f"frost-usb-watchdog: Monitoring {boot_dev} (disk: {parent_disk})")
    sys.stdout.flush()

    # Ignore signals that would kill us during normal shutdown
    signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))

    # Main monitoring loop
    while True:
        if not device_present(boot_dev):
            print(f"frost-usb-watchdog: Device {boot_dev} removed! Shutting down...")
            sys.stdout.flush()
            initiate_shutdown()
            break
        time.sleep(POLL_INTERVAL)

if __name__ == "__main__":
    main()
