#!/usr/bin/env python3
"""
frost-persist - frOSt Persistence Manager

Allows users to define which files, directories, packages, and services
should persist across reboots/disconnects. Everything else is transient
and lives in a tmpfs overlay that is lost on power off.

Usage:
  frost-persist add <path>          Add a path to persistence
  frost-persist remove <path>       Remove a path from persistence
  frost-persist list                List all persistent paths
  frost-persist status              Show persistence status
  frost-persist pkg add <package>   Mark a package as persistent
  frost-persist pkg remove <pkg>    Unmark a persistent package
  frost-persist pkg list            List persistent packages
  frost-persist sync                Force sync persistent data to disk
  frost-persist reset               Reset a path to base system state
"""

import os
import sys
import json
import shutil
import subprocess
import argparse


# Paths
FROST_CONFIG_DIR = "/etc/frost"
OVERLAY_INFO = f"{FROST_CONFIG_DIR}/overlay.json"
PERSIST_CONFIG = None  # Loaded dynamically
PERSIST_DATA = None


def load_overlay_info():
    """Load overlay mount information."""
    global PERSIST_CONFIG, PERSIST_DATA
    if os.path.exists(OVERLAY_INFO):
        with open(OVERLAY_INFO) as f:
            info = json.load(f)
        PERSIST_DATA = info.get("persist_data", "/frost/persist/data")
        PERSIST_CONFIG = os.path.join(
            info.get("persist", "/frost/persist"), "frost-persist.json"
        )
    else:
        PERSIST_DATA = "/frost/persist/data"
        PERSIST_CONFIG = "/frost/persist/frost-persist.json"


def load_config():
    """Load the persistence configuration."""
    if os.path.exists(PERSIST_CONFIG):
        with open(PERSIST_CONFIG) as f:
            return json.load(f)
    return {
        "version": 1,
        "persistent_paths": [],
        "persistent_packages": [],
        "persistent_services": [],
        "user_settings": {
            "auto_persist_home": True,
            "persist_logs": False,
            "persist_tmp": False,
        }
    }


def save_config(config):
    """Save the persistence configuration."""
    os.makedirs(os.path.dirname(PERSIST_CONFIG), exist_ok=True)
    with open(PERSIST_CONFIG, 'w') as f:
        json.dump(config, f, indent=2)
    print(f"\033[1;32m[OK]\033[0m Configuration saved")


def cmd_add(args):
    """Add a path to persistent storage."""
    path = os.path.abspath(args.path)
    config = load_config()

    if path in config["persistent_paths"]:
        print(f"\033[1;33m[WARN]\033[0m {path} is already persistent")
        return 1

    config["persistent_paths"].append(path)

    # Copy current data to persistence store
    persist_store = f"{PERSIST_DATA}{path}"
    if os.path.exists(path) and not os.path.exists(persist_store):
        os.makedirs(os.path.dirname(persist_store), exist_ok=True)
        if os.path.isdir(path):
            shutil.copytree(path, persist_store, symlinks=True, dirs_exist_ok=True)
        else:
            shutil.copy2(path, persist_store)
        print(f"\033[1;32m[OK]\033[0m Copied {path} to persistent storage")

    # Bind mount
    if os.path.exists(persist_store):
        subprocess.run(
            f"mount --bind {persist_store} {path}",
            shell=True, check=False
        )
        print(f"\033[1;32m[OK]\033[0m Bind mounted {path} (active now)")

    save_config(config)
    print(f"\033[1;32m[OK]\033[0m Added {path} to persistent paths")
    return 0


def cmd_remove(args):
    """Remove a path from persistent storage."""
    path = os.path.abspath(args.path)
    config = load_config()

    if path not in config["persistent_paths"]:
        print(f"\033[1;33m[WARN]\033[0m {path} is not in persistent paths")
        return 1

    config["persistent_paths"].remove(path)

    # Unmount bind mount if active
    subprocess.run(f"umount {path} 2>/dev/null", shell=True, check=False)

    save_config(config)
    print(f"\033[1;32m[OK]\033[0m Removed {path} from persistent paths")
    print(f"\033[1;33m[NOTE]\033[0m Data still exists in {PERSIST_DATA}{path}")
    print(f"       Use 'frost-persist purge {path}' to delete persistent data")
    return 0


def cmd_list(args):
    """List all persistent paths."""
    config = load_config()
    paths = config.get("persistent_paths", [])

    if not paths:
        print("No persistent paths configured.")
        return 0

    print(f"\033[1;36mfrOSt Persistent Paths\033[0m")
    print(f"{'Path':<50} {'Status':<15} {'Size':<10}")
    print("-" * 75)

    for path in sorted(paths):
        persist_store = f"{PERSIST_DATA}{path}"
        if os.path.exists(persist_store):
            # Check if bind mount is active
            mount_check = subprocess.run(
                f"mountpoint -q {path} 2>/dev/null",
                shell=True, check=False
            )
            status = "\033[1;32mACTIVE\033[0m" if mount_check.returncode == 0 else "\033[1;33mSTORED\033[0m"

            # Get size
            try:
                result = subprocess.run(
                    f"du -sh {persist_store} 2>/dev/null | cut -f1",
                    shell=True, capture_output=True, text=True
                )
                size = result.stdout.strip() or "?"
            except Exception:
                size = "?"
        else:
            status = "\033[1;31mMISSING\033[0m"
            size = "-"

        print(f"{path:<50} {status:<24} {size:<10}")

    return 0


def cmd_status(args):
    """Show persistence system status."""
    print(f"\033[1;36mfrOSt Persistence Status\033[0m")
    print("=" * 50)

    # Read /proc/mounts to detect actual mount state
    mounts = ""
    try:
        with open("/proc/mounts") as f:
            mounts = f.read()
    except IOError:
        pass

    # Check overlay mount (after switch_root, overlay is at /)
    overlay_active = "overlay on / " in mounts or "overlay / " in mounts
    if not overlay_active:
        overlay_active = os.path.ismount("/frost/merged") if os.path.exists("/frost/merged") else False
    print(f"Overlay filesystem: {'ACTIVE' if overlay_active else 'INACTIVE'}")

    # Check persistence partition
    persist_mounted = os.path.ismount("/frost/persist") if os.path.exists("/frost/persist") else False
    if not persist_mounted:
        persist_mounted = "/frost/persist" in mounts
    print(f"Persistence partition: {'MOUNTED' if persist_mounted else 'NOT MOUNTED'}")

    # Show disk usage
    if persist_mounted:
        result = subprocess.run(
            "df -h /frost/persist | tail -1",
            shell=True, capture_output=True, text=True
        )
        if result.stdout.strip():
            parts = result.stdout.strip().split()
            if len(parts) >= 4:
                print(f"Persistence space: {parts[2]} used / {parts[1]} total ({parts[4]})")

    # Count persistent items
    config = load_config()
    print(f"\nPersistent paths:    {len(config.get('persistent_paths', []))}")
    print(f"Persistent packages: {len(config.get('persistent_packages', []))}")
    print(f"Persistent services: {len(config.get('persistent_services', []))}")

    # Show tmpfs usage
    upper_path = "/frost/upper"
    if os.path.exists(upper_path):
        result = subprocess.run(
            f"df -h {upper_path} 2>/dev/null | tail -1",
            shell=True, capture_output=True, text=True
        )
        if result.stdout.strip():
            parts = result.stdout.strip().split()
            if len(parts) >= 4:
                print(f"\nTransient layer: {parts[2]} used / {parts[1]} total")

    return 0


def cmd_pkg_add(args):
    """Mark a package as persistent."""
    config = load_config()
    pkg = args.package

    if pkg in config.get("persistent_packages", []):
        print(f"\033[1;33m[WARN]\033[0m {pkg} is already persistent")
        return 1

    # Check if package is installed
    result = subprocess.run(
        f"dpkg -l {pkg} 2>/dev/null | grep '^ii'",
        shell=True, capture_output=True, text=True
    )
    if not result.stdout.strip():
        print(f"\033[1;33m[WARN]\033[0m {pkg} is not installed. Install it first with: apt install {pkg}")
        return 1

    config.setdefault("persistent_packages", []).append(pkg)

    # Get list of files owned by the package and persist them
    result = subprocess.run(
        f"dpkg -L {pkg} 2>/dev/null",
        shell=True, capture_output=True, text=True
    )
    pkg_files = [f for f in result.stdout.strip().split('\n') if os.path.isfile(f)]

    # Store package files to persistence
    pkg_store = f"{PERSIST_DATA}/var/lib/frost/packages/{pkg}"
    os.makedirs(pkg_store, exist_ok=True)
    with open(f"{pkg_store}/files.list", 'w') as f:
        f.write('\n'.join(pkg_files))

    # Copy key package directories
    pkg_dirs = set()
    for filepath in pkg_files:
        dirpath = os.path.dirname(filepath)
        if dirpath not in pkg_dirs:
            pkg_dirs.add(dirpath)

    for dirpath in pkg_dirs:
        persist_dir = f"{PERSIST_DATA}{dirpath}"
        os.makedirs(persist_dir, exist_ok=True)
        for filepath in pkg_files:
            if os.path.dirname(filepath) == dirpath:
                persist_file = f"{PERSIST_DATA}{filepath}"
                if os.path.exists(filepath):
                    shutil.copy2(filepath, persist_file)

    # Save dpkg status for this package
    dpkg_store = f"{PERSIST_DATA}/var/lib/dpkg"
    os.makedirs(dpkg_store, exist_ok=True)

    save_config(config)
    print(f"\033[1;32m[OK]\033[0m Package {pkg} marked as persistent ({len(pkg_files)} files)")
    return 0


def cmd_pkg_remove(args):
    """Unmark a package from persistence."""
    config = load_config()
    pkg = args.package

    pkgs = config.get("persistent_packages", [])
    if pkg not in pkgs:
        print(f"\033[1;33m[WARN]\033[0m {pkg} is not in persistent packages")
        return 1

    pkgs.remove(pkg)
    save_config(config)
    print(f"\033[1;32m[OK]\033[0m Package {pkg} removed from persistence")
    return 0


def cmd_pkg_list(args):
    """List persistent packages."""
    config = load_config()
    pkgs = config.get("persistent_packages", [])

    if not pkgs:
        print("No persistent packages configured.")
        return 0

    print(f"\033[1;36mfrOSt Persistent Packages\033[0m")
    print("-" * 40)
    for pkg in sorted(pkgs):
        print(f"  {pkg}")

    return 0


def cmd_sync(args):
    """Force sync persistent data to disk."""
    print("Syncing persistent data to disk...")
    config = load_config()

    for path in config.get("persistent_paths", []):
        persist_store = f"{PERSIST_DATA}{path}"
        if os.path.exists(path):
            subprocess.run(
                f"rsync -a --delete {path}/ {persist_store}/ 2>/dev/null || cp -a {path}/* {persist_store}/ 2>/dev/null",
                shell=True, check=False
            )

    # Sync filesystem
    subprocess.run("sync", shell=True, check=False)
    print(f"\033[1;32m[OK]\033[0m Sync complete")
    return 0


def cmd_reset(args):
    """Reset a persistent path to base system state."""
    path = os.path.abspath(args.path)
    config = load_config()

    if path not in config.get("persistent_paths", []):
        print(f"\033[1;33m[WARN]\033[0m {path} is not a persistent path")
        return 1

    persist_store = f"{PERSIST_DATA}{path}"

    # Unmount bind mount
    subprocess.run(f"umount {path} 2>/dev/null", shell=True, check=False)

    # Remove persistent data
    if os.path.exists(persist_store):
        if os.path.isdir(persist_store):
            shutil.rmtree(persist_store)
        else:
            os.remove(persist_store)
        print(f"\033[1;32m[OK]\033[0m Reset {path} to base system state")
    else:
        print(f"\033[1;33m[WARN]\033[0m No persistent data found for {path}")

    return 0


def main():
    parser = argparse.ArgumentParser(
        prog="frost-persist",
        description="frOSt Persistence Manager - Control what survives a reboot"
    )
    subparsers = parser.add_subparsers(dest="command")

    # add
    p_add = subparsers.add_parser("add", help="Add a path to persistence")
    p_add.add_argument("path", help="Path to make persistent")

    # remove
    p_rm = subparsers.add_parser("remove", help="Remove a path from persistence")
    p_rm.add_argument("path", help="Path to remove from persistence")

    # list
    subparsers.add_parser("list", help="List all persistent paths")

    # status
    subparsers.add_parser("status", help="Show persistence status")

    # pkg subcommand
    p_pkg = subparsers.add_parser("pkg", help="Manage persistent packages")
    pkg_sub = p_pkg.add_subparsers(dest="pkg_command")

    p_pkg_add = pkg_sub.add_parser("add", help="Mark package as persistent")
    p_pkg_add.add_argument("package", help="Package name")

    p_pkg_rm = pkg_sub.add_parser("remove", help="Unmark persistent package")
    p_pkg_rm.add_argument("package", help="Package name")

    pkg_sub.add_parser("list", help="List persistent packages")

    # sync
    subparsers.add_parser("sync", help="Force sync persistent data")

    # reset
    p_reset = subparsers.add_parser("reset", help="Reset path to base state")
    p_reset.add_argument("path", help="Path to reset")

    args = parser.parse_args()

    load_overlay_info()

    if args.command == "add":
        return cmd_add(args)
    elif args.command == "remove":
        return cmd_remove(args)
    elif args.command == "list":
        return cmd_list(args)
    elif args.command == "status":
        return cmd_status(args)
    elif args.command == "pkg":
        if args.pkg_command == "add":
            return cmd_pkg_add(args)
        elif args.pkg_command == "remove":
            return cmd_pkg_remove(args)
        elif args.pkg_command == "list":
            return cmd_pkg_list(args)
        else:
            p_pkg.print_help()
            return 1
    elif args.command == "sync":
        return cmd_sync(args)
    elif args.command == "reset":
        return cmd_reset(args)
    else:
        parser.print_help()
        return 1


if __name__ == "__main__":
    sys.exit(main())
