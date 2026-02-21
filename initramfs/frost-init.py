#!/usr/bin/env python3
"""
frOSt Init System - Python-based initialization
Runs inside the initramfs after the assembly early_init stub.
Responsible for:
  1. Finding the frOSt USB device and its partitions
  2. Mounting the read-only squashfs root
  3. Setting up the overlayfs (transient tmpfs + read-only lower)
  4. Mounting the persistence partition
  5. Applying persistent bind mounts based on user configuration
"""

import os
import sys
import json
import subprocess
import glob as globmod
import time

# Constants
FROST_BASE = "/frost"
LOWER_DIR = f"{FROST_BASE}/lower"
UPPER_DIR = f"{FROST_BASE}/upper"
WORK_DIR = f"{FROST_BASE}/work"
MERGED_DIR = f"{FROST_BASE}/merged"
PERSIST_DIR = f"{FROST_BASE}/persist"
PERSIST_CONFIG = f"{PERSIST_DIR}/frost-persist.json"
PERSIST_DATA = f"{PERSIST_DIR}/data"

# Default persistence config
DEFAULT_CONFIG = {
    "version": 1,
    "persistent_paths": [
        "/etc/frost",
        "/home",
        "/var/lib/apt",
        "/var/cache/apt",
        "/etc/NetworkManager/system-connections",
        "/etc/hostname",
        "/etc/hosts",
        "/etc/fstab",
    ],
    "persistent_packages": [],
    "persistent_services": [],
    "user_settings": {
        "auto_persist_home": True,
        "persist_logs": False,
        "persist_tmp": False,
    }
}


def log(msg, level="INFO"):
    """Log a message with frOSt prefix."""
    colors = {
        "INFO": "\033[1;37m",
        "OK": "\033[1;32m",
        "WARN": "\033[1;33m",
        "ERROR": "\033[1;31m",
    }
    color = colors.get(level, "\033[0m")
    reset = "\033[0m"
    print(f"{color}[frOSt-init] [{level}] {msg}{reset}", flush=True)


def run(cmd, check=True, capture=False):
    """Run a shell command."""
    log(f"exec: {cmd}", "INFO")
    result = subprocess.run(
        cmd, shell=True, check=check,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        text=True
    )
    return result


def find_frost_device():
    """
    Find the frOSt USB device by looking for the partition with
    label 'FROST_ROOT' or by scanning for squashfs partitions.
    Returns (root_partition, persist_partition) device paths.
    """
    log("Searching for frOSt USB device...")

    # Wait for device nodes to appear (up to 10 seconds)
    for attempt in range(20):
        # Method 1: Look for labeled partitions via /dev/disk/by-label
        if os.path.exists("/dev/disk/by-label/FROST_ROOT"):
            root_dev = os.path.realpath("/dev/disk/by-label/FROST_ROOT")
            log(f"Found FROST_ROOT at {root_dev}", "OK")
            # Persistence partition should be the next partition
            persist_label = "/dev/disk/by-label/FROST_PERSIST"
            if os.path.exists(persist_label):
                persist_dev = os.path.realpath(persist_label)
            else:
                # Derive: if root is sdX2, persist is sdX3
                persist_dev = derive_next_partition(root_dev)
            return root_dev, persist_dev

        # Method 2: Scan /sys/block for removable USB devices
        for block_dir in sorted(globmod.glob("/sys/block/sd*")):
            dev_name = os.path.basename(block_dir)
            removable_path = f"{block_dir}/removable"
            if os.path.exists(removable_path):
                with open(removable_path) as f:
                    if f.read().strip() == "1":
                        # Found a removable device, check partitions
                        root_dev = f"/dev/{dev_name}2"
                        persist_dev = f"/dev/{dev_name}3"
                        if os.path.exists(root_dev):
                            log(f"Found removable device /dev/{dev_name}", "OK")
                            return root_dev, persist_dev

        # Method 3: For QEMU testing - look for virtio devices
        for vd_path in sorted(globmod.glob("/sys/block/vd*")):
            dev_name = os.path.basename(vd_path)
            root_dev = f"/dev/{dev_name}2"
            persist_dev = f"/dev/{dev_name}3"
            if os.path.exists(root_dev):
                log(f"Found virtio device /dev/{dev_name}", "OK")
                return root_dev, persist_dev

        # Method 4: Also check for loop devices or any device with partitions
        for pattern in ["/dev/sda", "/dev/vda", "/dev/loop0"]:
            root_dev = f"{pattern}2"  # partition 2 = squashfs root
            persist_dev = f"{pattern}3"  # partition 3 = persistence
            if os.path.exists(root_dev):
                log(f"Found device {pattern}", "OK")
                return root_dev, persist_dev

        time.sleep(0.5)

    log("No frOSt device found! Trying fallback...", "WARN")
    # Absolute fallback: try /dev/sda
    return "/dev/sda2", "/dev/sda3"


def derive_next_partition(dev_path):
    """Given /dev/sdX2, return /dev/sdX3."""
    import re
    match = re.match(r'(/dev/\w+?)(\d+)$', dev_path)
    if match:
        base = match.group(1)
        num = int(match.group(2))
        return f"{base}{num + 1}"
    return dev_path.rstrip('0123456789') + '3'


def mount_squashfs_root(root_dev):
    """Mount the squashfs root filesystem as the lower overlay layer."""
    log(f"Mounting squashfs root from {root_dev}...")

    os.makedirs(LOWER_DIR, exist_ok=True)
    result = run(
        f"mount -t squashfs -o ro,loop {root_dev} {LOWER_DIR}",
        check=False
    )

    if result.returncode != 0:
        # Maybe it's ext4 with a squashfs file inside
        tmp_mount = "/frost/tmp_root"
        os.makedirs(tmp_mount, exist_ok=True)
        run(f"mount -o ro {root_dev} {tmp_mount}", check=False)

        squashfs_path = f"{tmp_mount}/rootfs.squashfs"
        if os.path.exists(squashfs_path):
            run(f"mount -t squashfs -o ro,loop {squashfs_path} {LOWER_DIR}")
            log("Mounted squashfs from rootfs.squashfs", "OK")
            return True

        # Maybe it's a direct ext4 root
        run(f"umount {tmp_mount}", check=False)
        run(f"mount -o ro {root_dev} {LOWER_DIR}", check=False)
        if os.path.exists(f"{LOWER_DIR}/sbin/init") or os.path.exists(f"{LOWER_DIR}/bin/sh"):
            log("Mounted ext4 root directly (no squashfs)", "OK")
            return True

        log("Failed to mount root filesystem!", "ERROR")
        return False

    log("Squashfs root mounted", "OK")
    return True


def setup_overlayfs():
    """Set up the overlayfs combining read-only root + tmpfs upper."""
    log("Setting up overlayfs...")

    # Ensure upper and work dirs exist on the tmpfs
    os.makedirs(f"{UPPER_DIR}/upper", exist_ok=True)
    os.makedirs(f"{UPPER_DIR}/work", exist_ok=True)
    os.makedirs(MERGED_DIR, exist_ok=True)

    overlay_opts = (
        f"lowerdir={LOWER_DIR},"
        f"upperdir={UPPER_DIR}/upper,"
        f"workdir={UPPER_DIR}/work"
    )

    result = run(
        f"mount -t overlay overlay -o {overlay_opts} {MERGED_DIR}",
        check=False
    )

    if result.returncode != 0:
        log("Overlayfs mount failed!", "ERROR")
        return False

    log("Overlayfs mounted successfully", "OK")
    return True


def mount_persistence(persist_dev):
    """Mount the persistence partition."""
    log(f"Mounting persistence partition {persist_dev}...")

    os.makedirs(PERSIST_DIR, exist_ok=True)

    result = run(
        f"mount -o rw {persist_dev} {PERSIST_DIR}",
        check=False
    )

    if result.returncode != 0:
        log(f"Cannot mount {persist_dev}, persistence disabled", "WARN")
        return False

    # Create data directory
    os.makedirs(PERSIST_DATA, exist_ok=True)

    log("Persistence partition mounted", "OK")
    return True


def load_persist_config():
    """Load or create the persistence configuration."""
    if os.path.exists(PERSIST_CONFIG):
        log("Loading persistence config...")
        try:
            with open(PERSIST_CONFIG) as f:
                config = json.load(f)
            log(f"Loaded config with {len(config.get('persistent_paths', []))} persistent paths", "OK")
            return config
        except (json.JSONDecodeError, IOError) as e:
            log(f"Error reading config: {e}", "WARN")

    log("Creating default persistence config...")
    save_persist_config(DEFAULT_CONFIG)
    return DEFAULT_CONFIG.copy()


def save_persist_config(config):
    """Save persistence configuration."""
    os.makedirs(os.path.dirname(PERSIST_CONFIG), exist_ok=True)
    with open(PERSIST_CONFIG, 'w') as f:
        json.dump(config, f, indent=2)


def apply_persistence(config):
    """
    Apply persistent bind mounts.
    For each path in persistent_paths:
      - If data exists in PERSIST_DATA/<path>, bind mount it over the overlay
      - If not, copy current content to PERSIST_DATA/<path> and then bind mount
    """
    log("Applying persistence bind mounts...")

    paths = config.get("persistent_paths", [])
    success_count = 0

    for path in paths:
        # Sanitize path
        path = path.strip()
        if not path or not path.startswith("/"):
            continue

        persist_store = f"{PERSIST_DATA}{path}"
        merged_path = f"{MERGED_DIR}{path}"

        try:
            if not os.path.exists(merged_path):
                # Path doesn't exist in the base system, create it
                os.makedirs(merged_path, exist_ok=True)

            if not os.path.exists(persist_store):
                # First boot: copy existing content to persistence
                os.makedirs(os.path.dirname(persist_store), exist_ok=True)
                if os.path.isdir(merged_path):
                    run(f"cp -a {merged_path} {persist_store}", check=False)
                else:
                    os.makedirs(os.path.dirname(persist_store), exist_ok=True)
                    run(f"cp -a {merged_path} {persist_store}", check=False)
                log(f"  Initialized persistence for {path}", "INFO")

            # Bind mount persistent data over the overlay
            if os.path.isdir(persist_store):
                os.makedirs(merged_path, exist_ok=True)
                result = run(
                    f"mount --bind {persist_store} {merged_path}",
                    check=False
                )
            else:
                # For files, ensure parent exists
                os.makedirs(os.path.dirname(merged_path), exist_ok=True)
                result = run(
                    f"mount --bind {persist_store} {merged_path}",
                    check=False
                )

            if result.returncode == 0:
                success_count += 1
                log(f"  Persisted: {path}", "OK")
            else:
                log(f"  Failed to persist: {path}", "WARN")

        except Exception as e:
            log(f"  Error persisting {path}: {e}", "ERROR")

    log(f"Applied {success_count}/{len(paths)} persistent bind mounts", "OK")


def setup_frost_tools():
    """
    Install frOSt management tools into the merged root so they're
    available after pivot_root.
    """
    log("Installing frOSt tools into merged root...")

    frost_bin = f"{MERGED_DIR}/usr/local/bin"
    frost_etc = f"{MERGED_DIR}/etc/frost"
    os.makedirs(frost_bin, exist_ok=True)
    os.makedirs(frost_etc, exist_ok=True)

    # Copy tools from initramfs if they exist
    tools = [
        ("/frost-persist.py", f"{frost_bin}/frost-persist"),
        ("/frost-config.py", f"{frost_bin}/frost-config"),
        ("/frost-overlay.py", f"{frost_bin}/frost-overlay"),
    ]

    for src, dst in tools:
        if os.path.exists(src):
            run(f"cp {src} {dst}", check=False)
            os.chmod(dst, 0o755)
            log(f"  Installed {os.path.basename(dst)}", "OK")

    # Write overlay info for tools to reference
    overlay_info = {
        "lower": LOWER_DIR,
        "upper": UPPER_DIR,
        "merged": MERGED_DIR,
        "persist": PERSIST_DIR,
        "persist_data": PERSIST_DATA,
    }
    info_path = f"{frost_etc}/overlay.json"
    with open(info_path, 'w') as f:
        json.dump(overlay_info, f, indent=2)


def setup_essential_mounts():
    """Create essential mount points and directories in merged root."""
    log("Setting up essential mount points...")

    essential_dirs = [
        f"{MERGED_DIR}/proc",
        f"{MERGED_DIR}/sys",
        f"{MERGED_DIR}/dev",
        f"{MERGED_DIR}/dev/pts",
        f"{MERGED_DIR}/dev/shm",
        f"{MERGED_DIR}/run",
        f"{MERGED_DIR}/tmp",
    ]

    for d in essential_dirs:
        os.makedirs(d, exist_ok=True)

    # Mount /dev/pts and /dev/shm in merged root
    run(f"mount -t devpts devpts {MERGED_DIR}/dev/pts 2>/dev/null", check=False)
    run(f"mount -t tmpfs tmpfs {MERGED_DIR}/dev/shm 2>/dev/null", check=False)
    run(f"mount -t tmpfs tmpfs {MERGED_DIR}/run 2>/dev/null", check=False)
    run(f"mount -t tmpfs tmpfs {MERGED_DIR}/tmp 2>/dev/null", check=False)


def main():
    """Main initialization sequence."""
    log("=" * 50)
    log("frOSt Init System v1.0")
    log("=" * 50)

    # Step 1: Find the frOSt device
    root_dev, persist_dev = find_frost_device()
    log(f"Root device: {root_dev}")
    log(f"Persist device: {persist_dev}")

    # Step 2: Mount squashfs root as lower layer
    if not mount_squashfs_root(root_dev):
        log("FATAL: Cannot mount root filesystem", "ERROR")
        return 1

    # Step 3: Set up overlayfs
    if not setup_overlayfs():
        log("FATAL: Cannot set up overlayfs", "ERROR")
        return 1

    # Step 4: Mount persistence partition
    has_persistence = mount_persistence(persist_dev)

    # Step 5: Load and apply persistence config
    if has_persistence:
        config = load_persist_config()
        apply_persistence(config)

    # Step 6: Set up essential mount points
    setup_essential_mounts()

    # Step 7: Install frOSt tools
    setup_frost_tools()

    log("=" * 50)
    log("frOSt initialization complete!", "OK")
    log("=" * 50)

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        log(f"FATAL: Unhandled exception: {e}", "ERROR")
        import traceback
        traceback.print_exc()
        sys.exit(1)
