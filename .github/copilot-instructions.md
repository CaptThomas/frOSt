# frOSt - Frozen Operating System

## Project Overview

frOSt is a Debian-based Linux OS designed for USB deployment with overlay filesystem architecture. The system uses a read-only squashfs base + tmpfs transient layer + ext4 persistent bind mounts. Everything resets on disconnect except user-defined persistent paths.

## Architecture

```
USB Drive (GPT):
  Partition 1: EFI (FAT32, 256MB) - GRUB + kernel + initramfs
  Partition 2: FROST_ROOT (ext4, 2.4GB) - contains rootfs.squashfs
  Partition 3: FROST_PERSIST (ext4, remaining) - persistent data

Boot Flow:
  UEFI/BIOS -> GRUB -> Linux kernel -> initramfs ->
  asm early_init -> shell /init -> overlayfs setup -> switch_root -> systemd -> LightDM -> XFCE4

Overlay Stack:
  /frost/merged (overlayfs) = /frost/lower (squashfs, RO) + /frost/upper (tmpfs, transient)
  Persistent bind mounts from /frost/persist/data/* over /frost/merged/*
```

## Directory Structure

```
boot/asm/early_init.asm   - x86-64 NASM assembly early init (mounts /proc, /sys, /dev)
initramfs/init            - Main init script (pure shell, runs in initramfs)
initramfs/frost-init.py   - Legacy Python init (abandoned, kept for reference)
tools/frost-persist.py    - Persistence manager CLI (runs in booted OS)
tools/frost-overlay.py    - Overlay filesystem manager CLI
tools/frost-config.py     - System configuration tool CLI
desktop/wallpaper.svg     - Custom frOSt wallpaper (1920x1080, converted to PNG at build)
desktop/frost-logo.svg    - frOSt crystal logo (converted to PNG at build)
desktop/lightdm/          - LightDM display manager configuration
desktop/xfce4/            - XFCE4 desktop environment defaults
desktop/gtk-3.0/gtk.css   - GTK3 theme overlay (frost colors on Adwaita-dark)
desktop/conky/            - Conky system monitor configuration
desktop/neofetch/         - Neofetch system info display
desktop/bashrc-frost      - Custom shell prompt (installed to /etc/profile.d/)
desktop/autostart/        - XDG autostart entries (conky)
build.sh                  - Master build script (runs as root in WSL/Linux)
rebuild_initramfs.sh      - Quick initramfs-only rebuild for iteration
test.sh                   - QEMU test runner (BIOS/UEFI/USB/Desktop modes)
```

## Build & Test Commands

```bash
# Full build (run as root in WSL Ubuntu)
sudo bash build.sh

# Quick initramfs rebuild (after modifying init script or tools)
sudo bash rebuild_initramfs.sh

# Test in QEMU
bash test.sh desktop       # Desktop mode (2GB RAM, virtio-vga) - recommended
bash test.sh bios          # BIOS mode with serial console
bash test.sh uefi          # UEFI mode
bash test.sh usb           # USB device simulation
bash test.sh headless      # Headless with 60s timeout
```

## Build Environment

- **Host**: Windows 11 with WSL2 (Ubuntu)
- **Build runs in**: WSL Ubuntu as root
- **Build directory**: `/root/frost-build/` (inside WSL)
- **Source on Windows**: `c:\Users\thoma\Documents\frOSt` (mapped to `/mnt/c/Users/thoma/Documents/frOSt` in WSL)
- **QEMU**: Windows installation at `C:\Program Files\qemu\`
- **Required tools**: debootstrap, nasm, grub, mtools, squashfs-tools, busybox-static, kpartx

## Key Technical Details

### Initramfs Init Script (`initramfs/init`)
- Pure POSIX shell (no Python in initramfs - Python module loading failed during boot)
- Uses `set +e` (errors handled manually, not with errexit)
- Loads kernel modules in dependency order; key dependencies:
  - `sd_mod` requires `t10-pi`, `crct10dif_*`, `scsi_mod`, `scsi_common`
  - `ext4` requires `jbd2`, `mbcache`, `crc16`
- Uses `mdev -s` for device node population (busybox udev alternative)
- Device detection: tries label lookup, blkid, then manual partition scanning
- Uses `switch_root` (not `pivot_root`) to transition from initramfs

### Kernel Module Dependencies
When adding new modules to the initramfs, copy entire subsystem directories from `kernel/` rather than individual `.ko` files. This avoids missing implicit dependencies. Critical directories: `block/`, `lib/`, `crypto/`, `arch/x86/crypto/`.

### Assembly Early Init (`boot/asm/early_init.asm`)
- Pure x86-64 Linux syscalls (no libc)
- Compiled with: `nasm -f elf64` + `ld --oformat=elf64-x86-64 -e _start --static`
- Mounts /proc, /sys, /dev; creates overlay directories; mounts tmpfs

### Python Tools (run after boot, not in initramfs)
- `frost-persist`: Manages persistent paths via bind mounts and JSON config at `/frost/persist/frost-persist.json`
- `frost-overlay`: Shows overlay status, diffs, layer info
- `frost-config`: User-facing configuration wizard
- Installed to `/usr/local/bin/` in the merged root

### Persistence Config (`frost-persist.json`)
```json
{
  "persistent_paths": ["/etc/frost", "/home", "/var/lib/apt", ...],
  "persistent_packages": [],
  "persistent_services": []
}
```
Paths are bind-mounted from `/frost/persist/data/<path>` over `/frost/merged/<path>`.

### Desktop Environment
- **DE**: XFCE4 with custom frOSt theme
- **Display Manager**: LightDM with GTK greeter, auto-login to `frost` user
- **Display Server**: Xorg with `xserver-xorg-video-all` drivers
- **GTK Theme**: Adwaita-dark with custom CSS overlay (`desktop/gtk-3.0/gtk.css`)
- **Color Palette**: Dark navy (#0a1628) background, cyan (#00d4ff) accents, red (#ff2d2d) highlights
- **Wallpaper**: Custom SVG at `desktop/wallpaper.svg`, converted to PNG at build time via `rsvg-convert`
- **System Monitor**: Conky overlay (top-right), auto-started via XDG autostart
- **Terminal**: XFCE4 Terminal with custom frost color palette, slight transparency
- **Font**: Hack (monospace), installed from `fonts-hack` package
- **GRUB**: Cyan/blue text theme with box-drawn frOSt banner
- **GPU modules**: `drm`, `drm_kms_helper`, `bochs-drm`, `virtio-gpu`, `simpledrm` loaded in initramfs

## Common Pitfalls

1. **WSL /tmp doesn't persist** - Build output goes to `/root/frost-build/`, not `/tmp/`
2. **Python won't work in initramfs** - The `encodings` module fails to load in the minimal initramfs environment. Keep the init script as pure shell.
3. **Module load order matters** - Dependencies must be loaded before dependents. The `load_mod` helper tries modprobe then insmod with fallback.
4. **File vs directory persistence** - The init script handles both: files use `cp -a` + file bind mount, directories use `mkdir -p` + directory bind mount.
5. **QEMU serial console** - Kernel cmdline must include `console=tty0 console=ttyS0,115200` for serial output; GRUB config needs `serial` and `terminal_input/output` directives.

## Login Credentials

- **User**: `frost` / **Password**: `frost` (has passwordless sudo)
- **Root password**: `frost`
- Auto-login enabled on tty1 (console) and via LightDM (desktop)
