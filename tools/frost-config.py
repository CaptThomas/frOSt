#!/usr/bin/env python3
"""
frost-config - frOSt System Configuration Tool

High-level tool for configuring the frOSt system. Wraps frost-persist
and frost-overlay with a user-friendly interface.

Usage:
  frost-config wizard                Interactive setup wizard
  frost-config show                  Show current configuration
  frost-config app persist <app>     Make an application persistent
  frost-config app transient <app>   Make an application transient (default)
  frost-config app list              List app persistence status
  frost-config settings              Show/edit system settings
"""

import os
import sys
import json
import subprocess
import argparse


FROST_CONFIG = "/etc/frost"
PERSIST_CONFIG = "/frost/persist/frost-persist.json"
APPS_CONFIG = f"{FROST_CONFIG}/apps.json"


def load_config(path):
    """Load a JSON config file."""
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    return {}


def save_config(config, path):
    """Save a JSON config file."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        json.dump(config, f, indent=2)


def get_app_paths(app_name):
    """Get filesystem paths associated with an application."""
    paths = []

    # Check dpkg for package files
    result = subprocess.run(
        f"dpkg -L {app_name} 2>/dev/null",
        shell=True, capture_output=True, text=True
    )
    if result.returncode == 0:
        # Get config directories
        for line in result.stdout.strip().split('\n'):
            line = line.strip()
            if line.startswith('/etc/') and os.path.isdir(line):
                paths.append(line)

    # Check for user config directories
    home = os.path.expanduser("~")
    user_configs = [
        f"{home}/.config/{app_name}",
        f"{home}/.{app_name}",
        f"{home}/.local/share/{app_name}",
    ]
    for cfg in user_configs:
        if os.path.exists(cfg):
            paths.append(cfg)

    # System config
    sys_configs = [
        f"/etc/{app_name}",
        f"/etc/{app_name}.conf",
        f"/var/lib/{app_name}",
    ]
    for cfg in sys_configs:
        if os.path.exists(cfg):
            paths.append(cfg)

    return paths


def cmd_wizard(args):
    """Interactive setup wizard."""
    print("\033[1;36m" + "=" * 50)
    print("  frOSt Configuration Wizard")
    print("=" * 50 + "\033[0m")
    print()
    print("This wizard will help you configure what persists")
    print("across reboots and what gets reset.")
    print()

    # Step 1: Home directory
    print("\033[1;37m[1/4] Home Directory\033[0m")
    print("  Your home directory contains personal files and settings.")
    choice = input("  Persist home directory? [Y/n]: ").strip().lower()
    persist_home = choice != 'n'

    # Step 2: Network
    print()
    print("\033[1;37m[2/4] Network Settings\033[0m")
    print("  WiFi passwords and network configurations.")
    choice = input("  Persist network settings? [Y/n]: ").strip().lower()
    persist_network = choice != 'n'

    # Step 3: Packages
    print()
    print("\033[1;37m[3/4] Installed Packages\033[0m")
    print("  By default, only base system packages are available.")
    print("  Additional packages must be marked persistent or reinstalled.")
    choice = input("  Persist apt package cache? [Y/n]: ").strip().lower()
    persist_apt = choice != 'n'

    # Step 4: Logs
    print()
    print("\033[1;37m[4/4] System Logs\033[0m")
    print("  Logs from /var/log.")
    choice = input("  Persist system logs? [y/N]: ").strip().lower()
    persist_logs = choice == 'y'

    # Build config
    persistent_paths = ["/etc/frost"]

    if persist_home:
        persistent_paths.append("/home")
    if persist_network:
        persistent_paths.append("/etc/NetworkManager/system-connections")
        persistent_paths.append("/etc/hostname")
        persistent_paths.append("/etc/hosts")
    if persist_apt:
        persistent_paths.append("/var/lib/apt")
        persistent_paths.append("/var/cache/apt")
        persistent_paths.append("/var/lib/dpkg")
    if persist_logs:
        persistent_paths.append("/var/log")

    config = {
        "version": 1,
        "persistent_paths": persistent_paths,
        "persistent_packages": [],
        "persistent_services": [],
        "user_settings": {
            "auto_persist_home": persist_home,
            "persist_logs": persist_logs,
            "persist_tmp": False,
        }
    }

    save_config(config, PERSIST_CONFIG)

    print()
    print("\033[1;32m[OK]\033[0m Configuration saved!")
    print(f"     {len(persistent_paths)} paths will persist across reboots")
    print()
    print("Use 'frost-persist add <path>' to add more persistent paths")
    print("Use 'frost-persist pkg add <package>' to persist installed packages")

    return 0


def cmd_show(args):
    """Show current configuration."""
    config = load_config(PERSIST_CONFIG)

    print("\033[1;36mfrOSt Configuration\033[0m")
    print("=" * 50)

    settings = config.get("user_settings", {})
    print(f"\n\033[1;37mSettings:\033[0m")
    print(f"  Auto-persist home:  {settings.get('auto_persist_home', False)}")
    print(f"  Persist logs:       {settings.get('persist_logs', False)}")
    print(f"  Persist /tmp:       {settings.get('persist_tmp', False)}")

    print(f"\n\033[1;37mPersistent Paths ({len(config.get('persistent_paths', []))}):\033[0m")
    for p in config.get("persistent_paths", []):
        print(f"  {p}")

    print(f"\n\033[1;37mPersistent Packages ({len(config.get('persistent_packages', []))}):\033[0m")
    for p in config.get("persistent_packages", []):
        print(f"  {p}")

    return 0


def cmd_app_persist(args):
    """Make an application persistent."""
    app = args.app
    paths = get_app_paths(app)

    if not paths:
        print(f"\033[1;33m[WARN]\033[0m No paths found for '{app}'")
        print(f"       Try: frost-persist add /path/to/config")
        return 1

    print(f"Persisting application: {app}")
    for path in paths:
        subprocess.run(
            f"frost-persist add {path}",
            shell=True, check=False
        )

    # Mark package as persistent too
    subprocess.run(
        f"frost-persist pkg add {app}",
        shell=True, check=False
    )

    # Save to apps config
    apps = load_config(APPS_CONFIG)
    apps.setdefault("persistent_apps", {})[app] = {
        "paths": paths,
        "package": app,
    }
    save_config(apps, APPS_CONFIG)

    print(f"\033[1;32m[OK]\033[0m {app} is now persistent")
    return 0


def cmd_app_transient(args):
    """Make an application transient (remove persistence)."""
    app = args.app
    apps = load_config(APPS_CONFIG)

    app_info = apps.get("persistent_apps", {}).get(app)
    if app_info:
        for path in app_info.get("paths", []):
            subprocess.run(
                f"frost-persist remove {path}",
                shell=True, check=False
            )
        del apps["persistent_apps"][app]
        save_config(apps, APPS_CONFIG)

    subprocess.run(
        f"frost-persist pkg remove {app}",
        shell=True, check=False
    )

    print(f"\033[1;32m[OK]\033[0m {app} is now transient (will reset on disconnect)")
    return 0


def cmd_app_list(args):
    """List applications and their persistence status."""
    apps = load_config(APPS_CONFIG)
    persistent = apps.get("persistent_apps", {})

    print("\033[1;36mfrOSt Application Persistence\033[0m")
    print("=" * 50)

    if persistent:
        print("\n\033[1;32mPersistent Apps:\033[0m")
        for app, info in sorted(persistent.items()):
            paths = info.get("paths", [])
            print(f"  {app} ({len(paths)} paths)")
    else:
        print("\nNo persistent apps configured.")

    print("\nAll other installed apps are TRANSIENT (reset on disconnect)")
    print("Use 'frost-config app persist <name>' to persist an app")
    return 0


def main():
    parser = argparse.ArgumentParser(
        prog="frost-config",
        description="frOSt System Configuration Tool"
    )
    subparsers = parser.add_subparsers(dest="command")

    subparsers.add_parser("wizard", help="Interactive setup wizard")
    subparsers.add_parser("show", help="Show configuration")
    subparsers.add_parser("settings", help="Show settings")

    p_app = subparsers.add_parser("app", help="Manage app persistence")
    app_sub = p_app.add_subparsers(dest="app_command")

    p_persist = app_sub.add_parser("persist", help="Make app persistent")
    p_persist.add_argument("app", help="Application/package name")

    p_trans = app_sub.add_parser("transient", help="Make app transient")
    p_trans.add_argument("app", help="Application/package name")

    app_sub.add_parser("list", help="List app status")

    args = parser.parse_args()

    if args.command == "wizard":
        return cmd_wizard(args)
    elif args.command == "show" or args.command == "settings":
        return cmd_show(args)
    elif args.command == "app":
        if args.app_command == "persist":
            return cmd_app_persist(args)
        elif args.app_command == "transient":
            return cmd_app_transient(args)
        elif args.app_command == "list":
            return cmd_app_list(args)
        else:
            p_app.print_help()
    else:
        parser.print_help()

    return 0


if __name__ == "__main__":
    sys.exit(main())
