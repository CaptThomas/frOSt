#!/usr/bin/env python3
"""
frost-overlay - frOSt Overlay Filesystem Manager

Provides visibility and management of the overlay filesystem layers.
Shows what files are modified in the transient layer, allows inspection
of the read-only base, and helps debug overlay issues.

Usage:
  frost-overlay status              Show overlay filesystem status
  frost-overlay diff                Show files modified in transient layer
  frost-overlay size                Show size of transient changes
  frost-overlay clean [--force]     Discard transient changes (reboot required)
  frost-overlay layers              Show overlay layer information
"""

import os
import sys
import json
import subprocess
import argparse


FROST_CONFIG_DIR = "/etc/frost"
OVERLAY_INFO = f"{FROST_CONFIG_DIR}/overlay.json"


def load_info():
    """Load overlay mount information."""
    defaults = {
        "lower": "/frost/lower",
        "upper": "/frost/upper",
        "merged": "/frost/merged",
        "persist": "/frost/persist",
        "persist_data": "/frost/persist/data",
    }
    if os.path.exists(OVERLAY_INFO):
        with open(OVERLAY_INFO) as f:
            return json.load(f)
    return defaults


def cmd_status(args):
    """Show overlay status."""
    info = load_info()

    print("\033[1;36mfrOSt Overlay Status\033[0m")
    print("=" * 60)

    # Read /proc/mounts to detect actual mount state
    mounts = ""
    try:
        with open("/proc/mounts") as f:
            mounts = f.read()
    except IOError:
        pass

    layers = [
        ("Lower (base)", info["lower"], "read-only squashfs"),
        ("Upper (transient)", info["upper"], "tmpfs (RAM)"),
        ("Merged (active root)", info["merged"], "overlayfs"),
        ("Persistence", info["persist"], "ext4 partition"),
    ]

    for name, path, desc in layers:
        # Check if mounted via /proc/mounts or os.path.ismount
        if path == "/" or path == info["merged"]:
            # After switch_root, overlay is at /
            mounted = "overlay on / " in mounts or "overlay / " in mounts
        else:
            mounted = os.path.ismount(path) if os.path.exists(path) else False
            # Also check /proc/mounts for the path
            if not mounted and path in mounts:
                mounted = True

        status = "\033[1;32mMOUNTED\033[0m" if mounted else "\033[1;31mNOT MOUNTED\033[0m"

        # Get usage if mounted
        usage = ""
        if mounted:
            check_path = "/" if (path == info["merged"]) else path
            result = subprocess.run(
                f"df -h {check_path} 2>/dev/null | tail -1",
                shell=True, capture_output=True, text=True
            )
            if result.stdout.strip():
                parts = result.stdout.strip().split()
                if len(parts) >= 5:
                    usage = f" ({parts[2]}/{parts[1]}, {parts[4]})"

        print(f"  {name:<25} {status}{usage}")
        print(f"  {'':25} {path} [{desc}]")
        print()

    return 0


def cmd_diff(args):
    """Show files modified in the transient upper layer."""
    info = load_info()
    upper = os.path.join(info["upper"], "upper")

    if not os.path.exists(upper):
        print("No transient changes (upper layer not found)")
        return 0

    print("\033[1;36mfrOSt Transient Changes\033[0m")
    print("Files modified since last boot (will be lost on disconnect):")
    print("=" * 60)

    file_count = 0
    dir_count = 0
    total_size = 0

    for root, dirs, files in os.walk(upper):
        # Calculate the relative path (what it maps to in /)
        rel_root = os.path.relpath(root, upper)
        if rel_root == ".":
            rel_root = ""

        for f in files:
            full_path = os.path.join(root, f)
            mapped_path = f"/{rel_root}/{f}" if rel_root else f"/{f}"

            # Check for overlayfs character devices (whiteouts = deletions)
            try:
                stat = os.lstat(full_path)
                size = stat.st_size
                total_size += size

                # Check for whiteout (deleted files)
                if os.path.islink(full_path) or (stat.st_mode & 0o170000 == 0o020000):
                    print(f"  \033[1;31mD\033[0m {mapped_path}")
                else:
                    print(f"  \033[1;33mM\033[0m {mapped_path} ({format_size(size)})")
                file_count += 1
            except OSError:
                pass

        dir_count += len(dirs)

    print(f"\n{file_count} files modified, {dir_count} directories, {format_size(total_size)} total")
    return 0


def cmd_size(args):
    """Show total size of transient changes."""
    info = load_info()
    upper = os.path.join(info["upper"], "upper")

    if not os.path.exists(upper):
        print("Upper layer: 0 bytes")
        return 0

    result = subprocess.run(
        f"du -sh {upper} 2>/dev/null | cut -f1",
        shell=True, capture_output=True, text=True
    )
    size = result.stdout.strip() or "0"
    print(f"Transient layer size: {size}")

    # Also show RAM usage
    result = subprocess.run(
        f"df -h {info['upper']} 2>/dev/null | tail -1",
        shell=True, capture_output=True, text=True
    )
    if result.stdout.strip():
        parts = result.stdout.strip().split()
        if len(parts) >= 5:
            print(f"tmpfs usage: {parts[2]} / {parts[1]} ({parts[4]})")

    return 0


def cmd_clean(args):
    """Mark transient layer for cleanup."""
    if not args.force:
        print("This will mark ALL transient changes for deletion on next boot.")
        print("Persistent data (managed by frost-persist) will NOT be affected.")
        confirm = input("Type 'yes' to confirm: ")
        if confirm.lower() != 'yes':
            print("Cancelled.")
            return 1

    # Write a flag file that init will read
    flag_path = "/frost/persist/.clean_transient"
    try:
        with open(flag_path, 'w') as f:
            f.write("clean")
        print("\033[1;32m[OK]\033[0m Transient layer will be cleaned on next boot")
    except IOError:
        print("\033[1;31m[ERROR]\033[0m Cannot write cleanup flag")
        return 1

    return 0


def cmd_layers(args):
    """Show detailed layer information."""
    info = load_info()

    print("\033[1;36mfrOSt Overlay Layers\033[0m")
    print("=" * 60)
    print()
    print("Layer stack (top = highest priority):")
    print()
    print("  ┌─────────────────────────────────────────────┐")
    print("  │  PERSIST BIND MOUNTS (selective paths)      │ <- User data")
    print("  ├─────────────────────────────────────────────┤")
    print("  │  UPPER: tmpfs (transient, RAM-based)        │ <- Lost on disconnect")
    print("  ├─────────────────────────────────────────────┤")
    print("  │  LOWER: squashfs (read-only base system)    │ <- Immutable")
    print("  └─────────────────────────────────────────────┘")
    print()

    # Show mount info from /proc/mounts
    print("Active mounts:")
    result = subprocess.run(
        "grep -E '(overlay|frost)' /proc/mounts 2>/dev/null",
        shell=True, capture_output=True, text=True
    )
    if result.stdout.strip():
        for line in result.stdout.strip().split('\n'):
            print(f"  {line}")
    else:
        print("  (overlay not yet mounted or not running inside frOSt)")

    return 0


def format_size(size_bytes):
    """Format bytes as human-readable size."""
    for unit in ['B', 'KB', 'MB', 'GB']:
        if size_bytes < 1024:
            return f"{size_bytes:.1f}{unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f}TB"


def main():
    parser = argparse.ArgumentParser(
        prog="frost-overlay",
        description="frOSt Overlay Filesystem Manager"
    )
    subparsers = parser.add_subparsers(dest="command")

    subparsers.add_parser("status", help="Show overlay status")
    subparsers.add_parser("diff", help="Show transient changes")
    subparsers.add_parser("size", help="Show transient layer size")

    p_clean = subparsers.add_parser("clean", help="Clean transient layer")
    p_clean.add_argument("--force", action="store_true", help="Skip confirmation")

    subparsers.add_parser("layers", help="Show layer information")

    args = parser.parse_args()

    if args.command == "status":
        return cmd_status(args)
    elif args.command == "diff":
        return cmd_diff(args)
    elif args.command == "size":
        return cmd_size(args)
    elif args.command == "clean":
        return cmd_clean(args)
    elif args.command == "layers":
        return cmd_layers(args)
    else:
        parser.print_help()
        return 1


if __name__ == "__main__":
    sys.exit(main())
