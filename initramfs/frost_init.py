#!/usr/bin/python3
"""
frOSt Init - Compiled Python Boot System
==========================================
Boot chain: GRUB -> kernel -> initramfs -> asm early_init -> shell shim -> THIS

The shell shim handles pre-Python tasks (the initramfs has no Python):
  1. Run assembly early_init (mount /proc, /sys, /dev, tmpfs)
  2. Load kernel modules
  3. Find and mount squashfs at /frost/lower (making Python available)
  4. Invoke THIS via the squashfs dynamic linker

This Python init handles:
  1. OverlayFS setup (squashfs RO lower + tmpfs RW upper)
  2. Persistence partition mount and bind mounts
  3. Merged root preparation (virtual filesystems, tools, config)
  4. USB watchdog service installation
  5. switch_root to systemd

Environment variables from shell shim:
  FROST_ROOT_DEV     - Block device for FROST_ROOT partition
  FROST_PERSIST_DEV  - Block device for FROST_PERSIST partition
"""

import os
import sys
import time
import json

# =============================================================================
# Constants
# =============================================================================
FROST_VERSION = "3.0.0"
OVERLAY_LOWER  = "/frost/lower"
OVERLAY_UPPER  = "/frost/upper"
OVERLAY_MERGED = "/frost/merged"
PERSIST_MNT    = "/frost/persist"

# =============================================================================
# ANSI Colors
# =============================================================================
CYAN    = "\033[1;36m"
GREEN   = "\033[1;32m"
RED     = "\033[1;31m"
YELLOW  = "\033[1;33m"
WHITE   = "\033[1;37m"
DIM     = "\033[0;37m"
BLUE    = "\033[1;34m"
RESET   = "\033[0m"

# =============================================================================
# Logging
# =============================================================================
def _write(s):
    sys.stdout.write(s)
    sys.stdout.flush()

def log(msg):
    _write(f"{DIM}[frOSt]{RESET} {msg}\n")

def ok(msg):
    _write(f"{GREEN}[frOSt]{RESET} {msg}\n")

def warn(msg):
    _write(f"{YELLOW}[frOSt] WARNING:{RESET} {msg}\n")

def fatal(msg):
    _write(f"\n{RED}[frOSt] {'=' * 50}{RESET}\n")
    _write(f"{RED}[frOSt] FATAL: {msg}{RESET}\n")
    _write(f"{RED}[frOSt] {'=' * 50}{RESET}\n\n")

# =============================================================================
# Helpers
# =============================================================================
def sh(cmd):
    """Run shell command, return exit code."""
    ret = os.system(f"{cmd} 2>/dev/null")
    return os.WEXITSTATUS(ret) if os.WIFEXITED(ret) else 1

def sh_ok(cmd):
    """Run shell command, return True if success."""
    return os.system(f"{cmd} 2>/dev/null") == 0

def read_file(path):
    try:
        with open(path, "r") as f:
            return f.read().strip()
    except Exception:
        return ""

def write_file(path, data):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(data)
        return True
    except Exception:
        return False

def makedirs(path):
    os.makedirs(path, mode=0o755, exist_ok=True)

# =============================================================================
# Step 1: OverlayFS setup
# =============================================================================
def setup_overlayfs():
    """Mount overlayfs: lower=squashfs RO, upper=tmpfs RW."""
    log("Setting up overlay filesystem...")
    makedirs(f"{OVERLAY_UPPER}/upper")
    makedirs(f"{OVERLAY_UPPER}/work")
    makedirs(OVERLAY_MERGED)

    if not sh_ok(
        f"mount -t overlay overlay "
        f"-o lowerdir={OVERLAY_LOWER},"
        f"upperdir={OVERLAY_UPPER}/upper,"
        f"workdir={OVERLAY_UPPER}/work "
        f"{OVERLAY_MERGED}"
    ):
        fatal("OverlayFS mount failed")
        return False
    ok("Overlay filesystem mounted")
    return True

# =============================================================================
# Step 2: Persistence
# =============================================================================
DEFAULT_PERSIST_CONFIG = {
    "persistent_paths": [
        "/etc/frost", "/home",
        "/var/lib/apt", "/var/cache/apt",
        "/etc/NetworkManager/system-connections",
        "/etc/hostname", "/etc/hosts"
    ],
    "auto_persist_home": True,
    "persist_logs": False,
    "persist_tmp": False,
}

def mount_persistence(persist_dev):
    """Mount the persistence partition."""
    if not persist_dev or not os.path.exists(persist_dev):
        return False
    log(f"Mounting persistence: {WHITE}{persist_dev}{RESET}")
    makedirs(PERSIST_MNT)
    if sh_ok(f"mount -o rw {persist_dev} {PERSIST_MNT}"):
        makedirs(f"{PERSIST_MNT}/data")
        ok("Persistence partition mounted")
        return True
    warn("Cannot mount persistence partition")
    return False

def apply_persistence():
    """Read frost-persist.json and bind-mount persistent paths."""
    config_path = f"{PERSIST_MNT}/frost-persist.json"

    if os.path.isfile(config_path):
        try:
            with open(config_path, "r") as f:
                config = json.load(f)
        except Exception as e:
            warn(f"Bad persistence config: {e}")
            config = DEFAULT_PERSIST_CONFIG
    else:
        config = DEFAULT_PERSIST_CONFIG
        try:
            with open(config_path, "w") as f:
                json.dump(config, f, indent=2)
        except Exception:
            pass

    paths = config.get("persistent_paths", [])
    bound = 0
    for p in sorted(set(paths)):
        p = p.strip()
        if not p or not p.startswith("/"):
            continue

        store  = f"{PERSIST_MNT}/data{p}"
        merged = f"{OVERLAY_MERGED}{p}"

        # Initialize storage directory/file from merged root if needed
        if not os.path.exists(store):
            os.makedirs(os.path.dirname(store), exist_ok=True)
            if os.path.isdir(merged):
                if sh(f"cp -a {merged} {store}") != 0:
                    makedirs(store)
            elif os.path.isfile(merged):
                sh(f"cp -a {merged} {store}")
            else:
                makedirs(store)

        # Bind mount
        if os.path.isdir(store):
            makedirs(merged)
            if sh_ok(f"mount --bind {store} {merged}"):
                bound += 1
        elif os.path.isfile(store) and os.path.isfile(merged):
            if sh_ok(f"mount --bind {store} {merged}"):
                bound += 1

    ok(f"Persistence: {bound}/{len(paths)} paths bound")

# =============================================================================
# Step 3: Prepare merged root
# =============================================================================
def prepare_merged_root(root_dev, persist_dev, has_persist):
    """Virtual filesystems, tools, config in merged root."""
    log("Preparing merged root...")

    # Essential directories
    for d in ["proc", "sys", "dev", "dev/pts", "dev/shm", "run", "tmp"]:
        makedirs(f"{OVERLAY_MERGED}/{d}")

    # Overlay internals accessible after switch_root
    for d in ["frost/lower", "frost/upper", "frost/persist"]:
        makedirs(f"{OVERLAY_MERGED}/{d}")

    sh_ok(f"mount --bind {OVERLAY_LOWER} {OVERLAY_MERGED}/frost/lower")
    sh_ok(f"mount --bind {OVERLAY_UPPER} {OVERLAY_MERGED}/frost/upper")
    if has_persist:
        sh_ok(f"mount --bind {PERSIST_MNT} {OVERLAY_MERGED}/frost/persist")

    # Virtual filesystems
    for fstype, src, dst in [
        ("proc",     "proc",     "proc"),
        ("sysfs",    "sysfs",    "sys"),
        ("devtmpfs", "devtmpfs", "dev"),
        ("devpts",   "devpts",   "dev/pts"),
        ("tmpfs",    "tmpfs",    "dev/shm"),
        ("tmpfs",    "tmpfs",    "run"),
        ("tmpfs",    "tmpfs",    "tmp"),
    ]:
        sh_ok(f"mount -t {fstype} {src} {OVERLAY_MERGED}/{dst}")

    # Install frOSt CLI tools
    tools_dir = f"{OVERLAY_MERGED}/usr/local/bin"
    makedirs(tools_dir)
    for tool in ["frost-persist.py", "frost-overlay.py", "frost-config.py"]:
        src = f"/{tool}"
        if os.path.isfile(src):
            dst_name = tool.replace(".py", "")
            dst = f"{tools_dir}/{dst_name}"
            sh(f"cp {src} {dst} && chmod 755 {dst}")

    # Write overlay metadata
    frost_etc = f"{OVERLAY_MERGED}/etc/frost"
    makedirs(frost_etc)
    overlay_info = {
        "version": FROST_VERSION,
        "init_type": "compiled_python_asm",
        "root_device": root_dev or "",
        "persist_device": persist_dev or "",
        "lower": "/frost/lower",
        "upper": "/frost/upper",
        "merged": "/",
        "persist": "/frost/persist",
        "boot_time": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }
    write_file(f"{frost_etc}/overlay.json", json.dumps(overlay_info, indent=2))

    # Record boot device for USB watchdog
    if root_dev:
        write_file(f"{frost_etc}/boot_device", root_dev)

    # Record base disk device (e.g., /dev/sda from /dev/sda2)
    boot_disk = _get_base_disk(root_dev) if root_dev else ""
    if boot_disk:
        write_file(f"{frost_etc}/boot_disk", boot_disk)

    ok("Merged root prepared")

def _get_base_disk(dev):
    """Get base disk device from partition device (e.g., /dev/sda2 -> /dev/sda)."""
    if not dev:
        return ""
    # /dev/sda2 -> /dev/sda, /dev/nvme0n1p2 -> /dev/nvme0n1
    name = os.path.basename(dev)
    if name.startswith(("nvme", "mmcblk")):
        # nvme0n1p2 -> nvme0n1
        i = name.rfind("p")
        if i > 0 and name[i+1:].isdigit():
            return f"/dev/{name[:i]}"
    else:
        # sda2 -> sda, vda3 -> vda
        i = len(name)
        while i > 0 and name[i-1].isdigit():
            i -= 1
        if i > 0:
            return f"/dev/{name[:i]}"
    return dev

# =============================================================================
# Step 4: switch_root
# =============================================================================
def switch_to_init():
    """switch_root to the merged overlay and exec systemd."""
    # Verify init exists
    init_path = "/sbin/init"
    if os.path.isfile(f"{OVERLAY_MERGED}/sbin/init"):
        ok("Found /sbin/init")
    elif os.path.isfile(f"{OVERLAY_MERGED}/lib/systemd/systemd"):
        init_path = "/lib/systemd/systemd"
        ok("Found systemd")
    else:
        warn("No init binary found - trying /sbin/init anyway")

    _write(f"\n{CYAN}{'─' * 50}{RESET}\n")
    _write(f"{CYAN}[frOSt]{RESET} {WHITE}Boot complete → starting system{RESET}\n")
    _write(f"{CYAN}{'─' * 50}{RESET}\n\n")

    # If we are PID 1, exec switch_root directly.
    # Otherwise (subprocess of shell init), write init_path for shell and exit 0.
    if os.getpid() == 1:
        os.execv("/bin/busybox", ["switch_root", OVERLAY_MERGED, init_path])
    else:
        # Write the init path so shell can use it
        write_file("/frost/.init_path", init_path)
        # Exit 0 to signal success to shell init
        sys.exit(0)

# =============================================================================
# Debug dump
# =============================================================================
def dump_debug_info():
    _write("\n")
    log("--- /proc/partitions ---")
    _write(read_file("/proc/partitions") + "\n\n")
    log("--- loaded modules ---")
    for line in read_file("/proc/modules").split("\n")[:30]:
        parts = line.split()
        if parts:
            _write(f"  {parts[0]}\n")
    _write("\n")

# =============================================================================
# Main
# =============================================================================
def main():
    _write(f"\n{BLUE}[frOSt]{RESET} {WHITE}Compiled Python init v{FROST_VERSION}{RESET}\n")
    _write(f"{BLUE}[frOSt]{RESET} {DIM}PID {os.getpid()} | Python {sys.version.split()[0]}{RESET}\n\n")

    # Get device info from shell shim
    root_dev    = os.environ.get("FROST_ROOT_DEV", "")
    persist_dev = os.environ.get("FROST_PERSIST_DEV", "")

    log(f"Root device:    {WHITE}{root_dev or '(none)'}{RESET}")
    log(f"Persist device: {WHITE}{persist_dev or '(none)'}{RESET}")

    # Step 1: OverlayFS
    if not setup_overlayfs():
        dump_debug_info()
        os.execv("/bin/sh", ["/bin/sh"])
        return

    # Step 2: Persistence
    has_persist = mount_persistence(persist_dev)
    if has_persist:
        apply_persistence()
    else:
        warn("Running without persistence")

    # Step 3: Prepare merged root + install USB watchdog
    prepare_merged_root(root_dev, persist_dev, has_persist)

    # Step 4: switch_root
    switch_to_init()


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        fatal(f"Unhandled exception: {e}")
        import traceback
        traceback.print_exc()
        _write(f"\n{DIM}[frOSt] Dropping to emergency shell...{RESET}\n")
        os.execv("/bin/sh", ["/bin/sh"])
