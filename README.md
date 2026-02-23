# frOSt - Frozen Operating System

<div align="center">

**A Debian-based Linux OS designed for USB deployment with overlay filesystem architecture**

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Linux-lightgrey.svg)](https://kernel.org)
[![Architecture](https://img.shields.io/badge/arch-x86__64-orange.svg)](https://en.wikipedia.org/wiki/X86-64)

</div>

---

## 🎯 Overview

frOSt is a specialized Linux distribution built on Debian that runs entirely from a USB drive. It uses an innovative overlay filesystem architecture that keeps the base system read-only while allowing temporary modifications in RAM and selective persistent storage for user-defined paths.

**Key Concept**: Everything resets on disconnect except what you explicitly mark as persistent.

## ✨ Features

- 🔒 **Immutable Base System**: Read-only squashfs root filesystem that cannot be corrupted
- 💾 **Smart Persistence**: Selective bind mounts for user-specified paths
- 🔄 **Transient Changes**: RAM-based overlay that resets on reboot
- 🖥️ **Full Desktop Environment**: XFCE4 with custom frOSt theme
- ⚡ **Fast Boot**: Optimized x86-64 assembly early init
- 🎨 **Custom Branding**: Unique crystal-themed UI with cyan/navy color scheme
- 🔧 **Management Tools**: Python CLIs for persistence and overlay management

## 🏗️ Architecture

### Partition Layout (GPT)
```
USB Drive:
├─ Partition 1: EFI (FAT32, 256MB)      - GRUB bootloader + kernel + initramfs
├─ Partition 2: FROST_ROOT (ext4, 2.4GB) - Contains rootfs.squashfs
└─ Partition 3: FROST_PERSIST (ext4, ~)  - Persistent user data
```

### Overlay Stack
```
/frost/merged (overlayfs)
  ├─ Lower Layer: /frost/lower (squashfs, read-only)
  └─ Upper Layer: /frost/upper (tmpfs, transient)
       └─ Persistent Mounts: from /frost/persist/data/*
```

### Boot Flow
```
UEFI/BIOS → GRUB → Linux Kernel → initramfs → 
asm early_init → shell /init → overlayfs setup → 
switch_root → systemd → LightDM → XFCE4
```

## 🛠️ Requirements

### Build Environment
- **Host OS**: Windows 11 with WSL2 (Ubuntu) or native Linux
- **Required Packages**:
  ```bash
  debootstrap nasm grub-pc-bin grub-efi-amd64-bin mtools 
  squashfs-tools busybox-static kpartx dosfstools xorriso
  ```
- **Build User**: Must run as root
- **Disk Space**: ~10GB free space recommended

### Testing Tools
- **QEMU**: For virtual machine testing
  - Windows: Install from https://qemu.org
  - Linux: `apt install qemu-system-x86`

## 🚀 Quick Start

### Building frOSt

```bash
# Clone or navigate to the repository
cd /path/to/frOSt

# Run the build script (requires root)
sudo bash build.sh
```

The build process will:
1. Create a Debian base system with debootstrap
2. Install XFCE4 desktop environment
3. Compile assembly early init
4. Build initramfs with kernel modules
5. Create squashfs root filesystem
6. Set up GRUB bootloader
7. Generate bootable USB image at `/root/frost-build/frost.img`

### Quick Initramfs Rebuild

For faster iteration when modifying init scripts or tools:

```bash
sudo bash rebuild_initramfs.sh
```

### Deploying to USB

#### PowerShell (Recommended - Windows)

The `deploy-usb.ps1` script writes the frOSt image to a USB drive. It auto-elevates to Administrator.

```powershell
# Auto-detect USB drive
powershell -ExecutionPolicy Bypass -File deploy-usb.ps1

# Specify disk number and skip confirmation
powershell -ExecutionPolicy Bypass -File deploy-usb.ps1 -DiskNumber 1 -Yes

# Use a pre-copied image file
powershell -ExecutionPolicy Bypass -File deploy-usb.ps1 -ImagePath C:\path\to\frost.img
```

You can also right-click `deploy-usb.ps1` and select **Run with PowerShell**.

**Options:**
| Flag | Description |
|------|-------------|
| `-DiskNumber N` | Target physical disk number (auto-detects USB if omitted) |
| `-ImagePath` | Path to frost.img on Windows filesystem |
| `-Yes` | Skip the confirmation prompt |

The script will:
1. Locate the frOSt image (from `-ImagePath`, project directory, or copy from WSL)
2. Detect USB drives and confirm the target
3. Write the raw image to the USB using direct disk I/O
4. Bring the disk back online

The persistence partition auto-expands to fill the USB on first boot via a systemd service.

#### Bash (Git Bash / WSL - Alternative)

```bash
# From an Administrator Git Bash terminal
bash deploy.sh --disk 1 --yes
```

#### Manual Deploy

If the automated scripts don't work on your system:

```bash
# 1. Copy image from WSL to Windows
wsl -d Ubuntu -u root -- bash -c "cp /root/frost-build/frost.img /mnt/c/Users/$USER/frost.img"

# 2. Write to USB with dd (from WSL, replace /dev/sdX with your USB device)
sudo dd if=/root/frost-build/frost.img of=/dev/sdX bs=4M status=progress conv=fsync

# 3. Fix GPT backup table and expand persistence
sudo sgdisk -e /dev/sdX
sudo parted -s /dev/sdX resizepart 3 100%
sudo e2fsck -f -y /dev/sdX3
sudo resize2fs /dev/sdX3
```

#### Booting from USB

1. Insert the USB into the target machine
2. Enter BIOS/UEFI boot menu (typically F12, F2, or DEL at startup)
3. Select the USB drive
4. Choose **frOSt Desktop** from the GRUB menu

### Testing with QEMU

```bash
# Desktop mode (recommended) - Full GUI with 2GB RAM
bash test.sh desktop

# Other test modes
bash test.sh bios      # BIOS boot with serial console
bash test.sh uefi      # UEFI boot
bash test.sh usb       # USB device simulation
bash test.sh headless  # Headless mode with 60s timeout
```

## 📂 Project Structure

```
frOSt/
├── boot/
│   └── asm/
│       └── early_init.asm         # x86-64 assembly early initialization
├── initramfs/
│   ├── init                       # Main init script (POSIX shell)
│   └── frost-init.py              # Legacy Python init (deprecated)
├── tools/
│   ├── frost-persist.py           # Persistence manager CLI
│   ├── frost-overlay.py           # Overlay filesystem manager
│   └── frost-config.py            # System configuration tool
├── desktop/
│   ├── wallpaper.svg              # Custom frOSt wallpaper (1920x1080)
│   ├── gtk-3.0/gtk.css            # GTK3 theme overlay
│   ├── lightdm/                   # Display manager config
│   ├── xfce4/                     # Desktop environment defaults
│   ├── conky/                     # System monitor config
│   └── bashrc-frost               # Custom shell prompt
├── build.sh                       # Master build script
├── rebuild_initramfs.sh           # Quick initramfs rebuild
├── deploy-usb.ps1                 # USB deploy script (PowerShell, Windows)
├── deploy.sh                      # USB deploy script (Bash)
└── test.sh                        # QEMU test runner
```

## 🔐 Default Credentials

- **User**: `frost` / **Password**: `frost`
  - Has passwordless sudo access
- **Root**: `frost`
- **Auto-login**: Enabled for console (tty1) and desktop (LightDM)

## 🎨 Desktop Environment

- **DE**: XFCE4 with custom frOSt theme
- **Display Manager**: LightDM with GTK greeter
- **GTK Theme**: Adwaita-dark with frOSt color overlay
- **Color Palette**: 
  - Background: Dark navy (#0a1628)
  - Accents: Cyan (#00d4ff)
  - Highlights: Red (#ff2d2d)
- **Terminal**: XFCE4 Terminal with custom frost palette
- **Font**: Hack (monospace)
- **System Monitor**: Conky overlay (auto-started)

## 🔧 Management Tools

### frost-persist
Manage persistent paths and configurations:
```bash
# Add a path to persistence
sudo frost-persist add /home

# Remove a path from persistence
sudo frost-persist remove /var/cache

# List persistent paths
frost-persist list

# Show persistence status
frost-persist status
```

### frost-overlay
Monitor overlay filesystem:
```bash
# Show overlay status
frost-overlay status

# Show differences between layers
frost-overlay diff

# Display layer information
frost-overlay info
```

### frost-config
User-facing configuration wizard:
```bash
sudo frost-config
```

## 📝 Persistence Configuration

Persistent paths are defined in `/frost/persist/frost-persist.json`:

```json
{
  "persistent_paths": [
    "/etc/frost",
    "/home",
    "/var/lib/apt"
  ],
  "persistent_packages": [],
  "persistent_services": []
}
```

Paths are bind-mounted from the FROST_PERSIST partition to the overlay.

## 🐛 Known Issues & Solutions

1. **Python doesn't work in initramfs**: The `encodings` module fails to load. Solution: Keep init script as pure POSIX shell.

2. **Module load order matters**: Dependencies must be loaded before dependents. The init script handles this with proper ordering.

3. **WSL /tmp doesn't persist**: Build output goes to `/root/frost-build/`, not `/tmp/`.

4. **Device detection delays**: The init script includes retry logic for device detection with `mdev -s`.

## 🔬 Development Notes

### Build Directory Structure (WSL)
- **Build path**: `/root/frost-build/` (inside WSL)
- **Source path**: `/mnt/c/Users/thoma/Documents/frOSt` (from Windows)
- **Output**: `/root/frost-build/frost.img`

### Kernel Module Dependencies
When adding modules to initramfs, copy entire subsystem directories from `kernel/` rather than individual `.ko` files to avoid missing implicit dependencies.

Critical directories: `block/`, `lib/`, `crypto/`, `arch/x86/crypto/`

### Assembly Early Init
- Pure x86-64 Linux syscalls (no libc)
- Compiled with: `nasm -f elf64` + `ld --oformat=elf64-x86-64`
- Mounts `/proc`, `/sys`, `/dev`

## 📜 License

MIT License - See [LICENSE](LICENSE) file for details

## 🤝 Contributing

Contributions are welcome! Please feel free to submit pull requests or open issues for bugs and feature requests.

## 🙏 Acknowledgments

- Built on Debian stable
- XFCE Desktop Environment
- GRUB bootloader
- OverlayFS kernel module

---

<div align="center">
Made with ❄️ by the frOSt team
</div>
