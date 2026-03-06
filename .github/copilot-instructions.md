# frOSt - Frozen Operating System

## Copilot Working Rules

Use these rules for any code changes in this repository:

- Treat `build.sh` as the single source of truth for system composition. Avoid adding parallel build paths unless explicitly requested.
- Prefer minimal, targeted edits over broad refactors, especially in boot-critical files (`initramfs/init`, `initramfs/frost_init.py`, `boot/asm/early_init.asm`).
- Preserve the hybrid boot handoff contract: shell discovers/mounts squashfs, Python handles overlay/persistence/switch_root.
- Keep initramfs shell code BusyBox-ash safe:
  - Do not use `local` outside function bodies.
  - Use integer sleep values only.
  - Handle errors explicitly; do not assume strict bash behavior.
- When changing module loading, keep dependency order intact and prefer subsystem directory inclusion over single `.ko` additions.
- Do not set `iwlwifi`/`iwlmvm` options that disable required AX201 init behavior (for example, avoid `enable_ini=0`).
- For persistence changes, maintain compatibility with `/frost/persist/frost-persist.json` and both file + directory bind-mount handling.
- Prefer quick validation paths before full rebuilds:
  - `rebuild-pyinit.sh` for initramfs iteration
  - `bash test.sh desktop` for end-to-end sanity checks
- Keep deploy workflows platform-correct:
  - Windows raw write path is `deploy.ps1`
  - Linux raw write path is `deploy.sh`

If a requested change conflicts with these constraints, call out the risk and suggest the safest alternative.

## Project Overview

frOSt is a Debian bookworm-based Linux OS designed for USB deployment with overlay filesystem architecture. The system uses a read-only squashfs base + tmpfs transient layer + ext4 persistent bind mounts. Everything resets on disconnect except user-defined persistent paths. Single build script (`build.sh`) is the source of truth for the entire OS.

## Architecture

```
USB Drive (GPT, 3GB image, expands on real hardware):
  Partition 1: EFI (FAT32, 256MB) - GRUB + kernel + initramfs
  Partition 2: FROST_ROOT (ext4, 2000MB) - contains rootfs.squashfs
  Partition 3: FROST_PERSIST (ext4, ~816MB in image, auto-expands to fill USB)

Boot Flow:
  UEFI -> GRUB -> Linux kernel 6.1 -> initramfs ->
  asm early_init -> shell /init -> overlayfs setup -> switch_root -> systemd -> LightDM -> XFCE4

Overlay Stack:
  /frost/merged (overlayfs) = /frost/lower (squashfs, RO) + /frost/upper (tmpfs, transient)
  Persistent bind mounts from /frost/persist/data/* over /frost/merged/*
```

### GRUB Menu Entries
1. **frOSt Desktop** - Normal graphical boot (quiet splash)
2. **frOSt Console** - Text-only (systemd.unit=multi-user.target)
3. **frOSt Recovery** - Single user mode
4. **frOSt Debug** - Debug with loglevel=7

## Directory Structure

```
build.sh                  - Master build script (single source of truth, runs as root in WSL/Linux)
frost.img                 - Built disk image (3GB, not tracked in git)

boot/asm/early_init.asm   - x86-64 NASM assembly early init (mounts /proc, /sys, /dev)
initramfs/init            - Shell shim (module loading, device detection, squashfs mount, Python handoff)
initramfs/frost_init.py   - Python init (overlayfs, persistence, merged root, switch_root)

tools/frost-persist.py    - Persistence manager CLI (runs in booted OS)
tools/frost-overlay.py    - Overlay filesystem manager CLI
tools/frost-config.py     - System configuration tool CLI
tools/frost-expand-persist.sh - Persistence partition auto-expand script
tools/frost-usb-watchdog.py - USB disconnect watchdog (triggers shutdown on USB removal)

desktop/wallpaper.svg     - Custom frOSt wallpaper (1920x1080, converted to PNG at build)
desktop/frost-logo.svg    - frOSt crystal logo (converted to PNG at build)
desktop/lightdm/          - LightDM display manager configuration
desktop/xfce4/            - XFCE4 desktop environment defaults (panel, desktop, terminal, window manager)
desktop/gtk-3.0/gtk.css   - GTK3 theme overlay (frost colors on Adwaita-dark)
desktop/conky/conky.conf  - Conky system monitor configuration
desktop/neofetch/         - Neofetch system info display + custom ASCII art
desktop/bashrc-frost      - Custom shell prompt (installed to /etc/profile.d/)
desktop/autostart/        - XDG autostart entries (conky, picom)
desktop/picom/picom.conf  - Picom compositor configuration (shadows, fading, transparency, rounded corners)

deploy.ps1                - Windows PowerShell USB deploy (Win32 raw disk I/O, auto-elevates)
deploy.sh                 - Linux USB deploy (dd + partition expansion)
test.sh                   - QEMU test runner (BIOS/UEFI/USB/Desktop modes)
rebuild-pyinit.sh         - Quick initramfs rebuild (asm + shell + Python, injects into image)
```

## Build & Test Commands

```bash
# Full build (run as root in WSL Ubuntu)
sudo bash build.sh

# Test in QEMU
bash test.sh desktop       # Desktop mode (2GB RAM, virtio-vga) - recommended
bash test.sh bios          # BIOS mode with serial console
bash test.sh uefi          # UEFI mode
bash test.sh usb           # USB device simulation
bash test.sh headless      # Headless with 60s timeout

# Deploy to USB (Windows)
powershell -ExecutionPolicy Bypass -File deploy.ps1
# Deploy to USB (Linux)
sudo bash deploy.sh /dev/sdX
```

## Build Environment

- **Host**: Windows 11 with WSL2 (Ubuntu)
- **Build runs in**: WSL Ubuntu as root
- **Build directory**: `/root/frost-build/` (inside WSL)
- **Source on Windows**: `c:\Users\thoma\Documents\frOSt` (mapped to `/mnt/c/Users/thoma/Documents/frOSt` in WSL)
- **QEMU**: Windows installation at `C:\Program Files\qemu\`
- **Target hardware**: ASUS TUF Dash F15 FX516PM (Tiger Lake, Intel Wi-Fi 6 AX201 CNVi, NVIDIA RTX 3060)
- **Required tools**: debootstrap, nasm, grub, mtools, squashfs-tools, busybox-static

## Key Technical Details

### Initramfs Init Script (`initramfs/init`)
- POSIX shell shim that hands off to Python after squashfs is mounted
- Shell handles: asm early_init, module loading, device detection, squashfs mounting
- Python (`initramfs/frost_init.py`) handles: overlayfs, persistence, merged root prep, switch_root
- Python is invoked from the squashfs via its own dynamic linker: `exec $LD_LINUX $PYBIN /frost_init.py`
- Uses `set +e` (errors handled manually, not with errexit)
- No `local` keyword outside functions (busybox ash crashes)
- Integer-only `sleep` values (busybox may not support fractional)
- Uses `mdev -s` for device node population (not udev)
- Device detection with 3 methods: `findfs` (primary), `/dev/disk/by-label/`, mount-probe
- Manual `/dev` node creation from `/sys/block` via `ensure_dev_nodes()` function
- Uevent re-triggering for USB/SCSI/PCI buses: `echo "add" > /sys/bus/*/devices/*/uevent`
- 30-second timeout for USB device enumeration
- Uses `switch_root` (not `pivot_root`) to transition from initramfs
- Full shell fallback if Python/linker not available (overlay + basic persistence + switch_root)

### Boot Sequence (hybrid shell+Python)
1. Run `/early_init` (assembly binary) or fallback to shell mounts
2. **Shell**: Load ~50+ kernel modules in dependency order (SCSI, ATA, USB, overlay, ext4, HID, DRM)
3. **Shell**: Device detection with mdev, uevent retriggering, manual /dev node creation
4. **Shell**: Find frOSt partitions (findfs, by-label, mount-probe)
5. **Shell**: Mount squashfs root at /frost/lower
6. **Shell→Python**: Hand off to `frost_init.py` via squashfs's `ld-linux-x86-64.so.2`
7. **Python**: OverlayFS setup (lower=squashfs RO, upper=tmpfs RW)
8. **Python**: Persistence (mount FROST_PERSIST, parse JSON, bind-mount paths)
9. **Python**: Prepare merged root (virtual filesystems, install tools, write overlay.json)
10. **Python**: `switch_root` to systemd

### Kernel Module Dependencies
When adding new modules to the initramfs, copy entire subsystem directories from `kernel/` rather than individual `.ko` files. This avoids missing implicit dependencies. Critical directories: `block/`, `lib/`, `crypto/`, `arch/x86/crypto/`. USB requires `drivers/usb/common` in addition to `core`, `host`, and `storage`.

### Assembly Early Init (`boot/asm/early_init.asm`)
- Pure x86-64 Linux syscalls (no libc)
- Compiled with: `nasm -f elf64` + `ld --oformat=elf64-x86-64 -e _start --static`
- Mounts /proc, /sys, /dev (devtmpfs); creates overlay directories; mounts tmpfs

### Systemd Services

**Enabled at boot:**
| Service | Description |
|---------|-------------|
| `frost-hwdetect.service` | Hardware detection (loads WiFi/GPU/audio modules based on PCI IDs, unblocks rfkill) |
| `frost-sync.service` | Persistence sync at shutdown |
| `frost-expand-persist.service` | Auto-expand persistence partition to fill full USB |
| `frost-boot-diag.service` | Boot diagnostics (writes logs to persistence) |
| `NetworkManager.service` | Network management |
| `wpa_supplicant.service` | WiFi WPA authentication |
| `systemd-timesyncd.service` | NTP time sync |
| `lightdm` | Display manager (auto-login) |

**Disabled/masked (boot speed):**
`NetworkManager-wait-online.service` (disabled+masked), `e2scrub_reap.service`, `systemd-pstore.service`, `remote-fs.target`, `plymouth-quit-wait.service` (masked)

### WiFi Stack (Intel AX201 / CNVi / Tiger Lake)
- **Firmware**: `firmware-iwlwifi` package (58 files including `iwlwifi-QuZ-a0-hr-b0-72.ucode`)
- **Modules**: iwlwifi, iwlmvm, cfg80211, mac80211, rfkill (autoloaded via `/etc/modules-load.d/iwlwifi.conf`)
- **Modprobe config**: `/etc/modprobe.d/iwlwifi.conf` with `options iwlmvm power_scheme=1`
- **Do NOT set `enable_ini=0`** — firmware v72+ requires INI tables for AX201 radio initialization
- **Services**: NetworkManager + wpa_supplicant (both must be enabled)
- **frost-hwdetect**: loads WiFi modules and runs `rfkill unblock wifi`
- **Diagnostic tool**: `frost-wifi-diag` (installed to `/usr/local/bin/`)

### Python Tools (run after boot, not in initramfs)
- `frost-persist`: Manages persistent paths via bind mounts and JSON config at `/frost/persist/frost-persist.json`
- `frost-overlay`: Shows overlay status, diffs, layer info
- `frost-config`: User-facing configuration wizard
- `frost-expand-persist`: Expands persistence partition to fill USB drive
- Installed to `/usr/local/bin/` in the merged root

### Persistence Config (`frost-persist.json`)
```json
{
  "persistent_paths": [
    "/etc/frost", "/home", "/var/lib/apt", "/var/cache/apt",
    "/etc/NetworkManager/system-connections", "/etc/hostname", "/etc/hosts"
  ],
  "auto_persist_home": true,
  "persist_logs": false,
  "persist_tmp": false
}
```
Paths are bind-mounted from `/frost/persist/data/<path>` over `/frost/merged/<path>`.

### Desktop Environment
- **DE**: XFCE4 with custom frOSt theme
- **Display Manager**: LightDM with GTK greeter, auto-login to `frost` user
- **Display Server**: Xorg with `xserver-xorg-video-all` drivers
- **Compositor**: Picom (xrender backend, shadows, fading, rounded corners, inactive opacity 0.92)
- **GTK Theme**: Adwaita-dark with custom CSS overlay (`desktop/gtk-3.0/gtk.css`)
- **Icon Theme**: Papirus
- **Color Palette**: Dark navy (#0a1628) background, cyan (#00d4ff) accents, red (#ff2d2d) highlights
- **Wallpaper**: Custom SVG at `desktop/wallpaper.svg`, converted to PNG at build time via `rsvg-convert`
- **System Monitor**: Conky overlay (top-right), auto-started via XDG autostart
- **Terminal**: XFCE4 Terminal with custom frost color palette, slight transparency (85%)
- **Font**: Hack (monospace), installed from `fonts-hack` package
- **Browser**: Firefox ESR
- **Audio**: PulseAudio + pavucontrol
- **GRUB**: Cyan/blue text theme with box-drawn frOSt banner
- **GPU modules**: drm, drm_kms_helper, bochs-drm, virtio-gpu, simpledrm loaded in initramfs

### Deploy Scripts
- **`deploy.ps1`** (Windows): Uses Win32 `CreateFile` API with `FSCTL_LOCK_VOLUME`/`FSCTL_DISMOUNT_VOLUME` for raw disk I/O. Auto-elevates to admin. Writes progress to `deploy-status.txt`. Targets disk 1 by default.
- **`deploy.sh`** (Linux): Uses `dd` to write image, then expands persistence partition with `parted`/`sgdisk` + `resize2fs`.

## Common Pitfalls

1. **WSL /tmp doesn't persist** - Build output goes to `/root/frost-build/`, not `/tmp/`
2. **Python won't work in initramfs directly** - The `encodings` module fails to load in the minimal initramfs environment. Python runs from the squashfs after it's mounted, invoked via the squashfs's own dynamic linker (`ld-linux-x86-64.so.2`). Direct `exec` of the squashfs Python binary fails with exit code 127 because the ELF interpreter path (`/lib64/ld-linux-x86-64.so.2`) doesn't exist in the initramfs — must use `exec $LD_LINUX $PYBIN` instead.
3. **Module load order matters** - Dependencies must be loaded before dependents. The `load_mod` helper tries modprobe then insmod with fallback.
4. **No `local` outside functions in init** - Busybox ash crashes with `local: not in a function`. Only use `local` inside function bodies.
5. **Integer-only sleep in init** - Busybox `sleep 0.5` is unreliable; use `sleep 1` or higher.
6. **USB needs `drivers/usb/common`** - Without usb-common.ko, usbcore fails to load, cascading failure for all USB storage.
7. **File vs directory persistence** - The init script handles both: files use `cp -a` + file bind mount, directories use `mkdir -p` + directory bind mount.
8. **QEMU serial console** - Kernel cmdline must include `console=tty0 console=ttyS0,115200` for serial output; GRUB config needs `serial` and `terminal_input/output` directives.
9. **iwlwifi enable_ini=0 breaks AX201** - Firmware v72+ requires INI tables. Setting `enable_ini=0` prevents radio initialization on Tiger Lake CNVi WiFi.
10. **WSL path translation** - Git for Windows rewrites `/mnt/c/...` paths. Use `MSYS_NO_PATHCONV=1` when passing paths to WSL, or use `-u root` instead of `sudo` (sudo may be disabled).
11. **Debootstrap components** - Must include `main,contrib,non-free,non-free-firmware` for WiFi firmware packages.
12. **Quick rebuild pattern** - Instead of full debootstrap rebuild, mount the image via losetup, extract squashfs to tmpdir, modify, rebuild squashfs, and redeploy. Much faster for iterative fixes.
13. **WSL losetup partition probing** - `losetup -fP` on NTFS-mounted `.img` files in WSL sometimes fails to create partition device nodes (`/dev/loopXpY`). Add `sleep 2` + `partprobe` after `losetup`. If partitions still don't appear, try `kpartx -av` or copy the image to a native ext4 path first.

## Login Credentials

- **User**: `frost` / **Password**: `frost` (has passwordless sudo)
- **Root password**: `frost`
- Auto-login enabled on tty1 (console) and via LightDM (desktop)
