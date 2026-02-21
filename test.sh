#!/bin/bash
# =============================================================================
# frOSt QEMU Test Runner
# =============================================================================
# Tests the frOSt disk image in QEMU with various configurations.
# Runs on Windows (Git Bash) using Windows QEMU installation.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="/root/frost-build"
IMAGE_FILE="${BUILD_DIR}/frost.img"
QEMU_WIN="/c/Program Files/qemu/qemu-system-x86_64.exe"

# Detect WSL or Git Bash
if grep -q Microsoft /proc/version 2>/dev/null; then
    IS_WSL=1
    # Convert WSL path to Windows path for QEMU
    IMAGE_FILE_WIN=$(wslpath -w "${IMAGE_FILE}" 2>/dev/null || echo "${IMAGE_FILE}")
else
    IS_WSL=0
    IMAGE_FILE_WIN="${IMAGE_FILE}"
fi

# Colors
RED='\033[1;31m'
GREEN='\033[1;32m'
CYAN='\033[1;36m'
RESET='\033[0m'

log() { echo -e "${CYAN}[frOSt-test]${RESET} $1"; }
ok()  { echo -e "${GREEN}[OK]${RESET} $1"; }
err() { echo -e "${RED}[ERROR]${RESET} $1"; exit 1; }

# =============================================================================
# Check prerequisites
# =============================================================================
check_prereqs() {
    log "Checking prerequisites..."

    if [[ ! -f "${IMAGE_FILE}" ]]; then
        # Try Windows path
        local win_path="//wsl.localhost/Ubuntu${IMAGE_FILE}"
        if [[ -f "${win_path}" ]]; then
            IMAGE_FILE="${win_path}"
        else
            err "Disk image not found: ${IMAGE_FILE}\nRun build.sh first."
        fi
    fi

    # Find QEMU
    if [[ -f "${QEMU_WIN}" ]]; then
        QEMU="${QEMU_WIN}"
    elif command -v qemu-system-x86_64 >/dev/null 2>&1; then
        QEMU="qemu-system-x86_64"
    else
        err "QEMU not found. Install QEMU first."
    fi

    ok "Prerequisites OK"
    log "Image: ${IMAGE_FILE}"
    log "QEMU: ${QEMU}"
}

# =============================================================================
# Download OVMF (UEFI firmware) if needed
# =============================================================================
get_ovmf() {
    local ovmf_path="${BUILD_DIR}/OVMF.fd"

    if [[ -f "${ovmf_path}" ]]; then
        echo "${ovmf_path}"
        return
    fi

    # Check project directory (Windows filesystem)
    local project_ovmf="${SCRIPT_DIR}/OVMF.fd"
    if [[ -f "${project_ovmf}" ]]; then
        echo "${project_ovmf}"
        return
    fi

    log "Downloading OVMF UEFI firmware..."

    # Try to find OVMF in common locations first
    local ovmf_locations=(
        "/usr/share/OVMF/OVMF_CODE.fd"
        "/usr/share/OVMF/OVMF_CODE_4M.fd"
        "/usr/share/ovmf/OVMF.fd"
        "/usr/share/edk2/ovmf/OVMF_CODE.fd"
        "/usr/share/qemu/OVMF.fd"
        "//wsl.localhost/Ubuntu/usr/share/OVMF/OVMF_CODE_4M.fd"
        "//wsl.localhost/Ubuntu/usr/share/OVMF/OVMF_CODE.fd"
    )

    for loc in "${ovmf_locations[@]}"; do
        if [[ -f "${loc}" ]]; then
            cp "${loc}" "${ovmf_path}"
            ok "Found OVMF at ${loc}"
            echo "${ovmf_path}"
            return
        fi
    done

    # Download from Debian/Ubuntu repo
    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y -qq ovmf 2>/dev/null || true
        for loc in "${ovmf_locations[@]}"; do
            if [[ -f "${loc}" ]]; then
                cp "${loc}" "${ovmf_path}"
                echo "${ovmf_path}"
                return
            fi
        done
    fi

    # Direct download as last resort
    local url="https://retrage.github.io/edk2-nightly/bin/RELEASEX64_OVMF.fd"
    if command -v wget >/dev/null 2>&1; then
        wget -q -O "${ovmf_path}" "${url}" 2>/dev/null || true
    elif command -v curl >/dev/null 2>&1; then
        curl -sL -o "${ovmf_path}" "${url}" 2>/dev/null || true
    fi

    if [[ -f "${ovmf_path}" ]]; then
        ok "OVMF downloaded"
    else
        warn "Could not get OVMF, will boot in BIOS mode"
    fi

    echo "${ovmf_path}"
}

# =============================================================================
# Test: Basic boot (BIOS mode)
# =============================================================================
test_bios_boot() {
    log "Test: BIOS boot..."

    local img_path="${IMAGE_FILE}"
    # Convert path for Windows QEMU if needed
    if [[ $IS_WSL -eq 1 ]]; then
        img_path="${IMAGE_FILE_WIN}"
    fi

    "${QEMU}" \
        -drive "file=${img_path},format=raw,if=virtio" \
        -m 1024 \
        -cpu qemu64 \
        -smp 2 \
        -net nic,model=virtio \
        -net user \
        -vga std \
        -serial stdio \
        -name "frOSt Test (BIOS)" \
        "$@"
}

# =============================================================================
# Test: UEFI boot
# =============================================================================
test_uefi_boot() {
    log "Test: UEFI boot..."

    local ovmf
    ovmf=$(get_ovmf)

    if [[ ! -f "${ovmf}" ]]; then
        log "Skipping UEFI test (no OVMF firmware)"
        return
    fi

    local img_path="${IMAGE_FILE}"
    local ovmf_path="${ovmf}"
    if [[ $IS_WSL -eq 1 ]]; then
        img_path="${IMAGE_FILE_WIN}"
        ovmf_path=$(wslpath -w "${ovmf}" 2>/dev/null || echo "${ovmf}")
    fi

    "${QEMU}" \
        -drive "file=${img_path},format=raw,if=virtio" \
        -bios "${ovmf_path}" \
        -m 1024 \
        -cpu qemu64 \
        -smp 2 \
        -net nic,model=virtio \
        -net user \
        -vga std \
        -serial stdio \
        -name "frOSt Test (UEFI)" \
        "$@"
}

# =============================================================================
# Test: USB simulation
# =============================================================================
test_usb_mode() {
    log "Test: USB device simulation..."

    local img_path="${IMAGE_FILE}"
    if [[ $IS_WSL -eq 1 ]]; then
        img_path="${IMAGE_FILE_WIN}"
    fi

    # Simulate USB mass storage device
    "${QEMU}" \
        -drive "if=none,id=usbdisk,file=${img_path},format=raw" \
        -device qemu-xhci,id=xhci \
        -device usb-storage,bus=xhci.0,drive=usbdisk,removable=on \
        -m 1024 \
        -cpu qemu64 \
        -smp 2 \
        -net nic,model=virtio \
        -net user \
        -vga std \
        -serial stdio \
        -name "frOSt Test (USB)" \
        "$@"
}

# =============================================================================
# Test: Desktop mode (GUI with higher RAM and better display)
# =============================================================================
test_desktop() {
    log "Test: Desktop mode (GUI)..."

    local img_path="${IMAGE_FILE}"
    if [[ $IS_WSL -eq 1 ]]; then
        img_path="${IMAGE_FILE_WIN}"
    fi

    # Desktop mode uses UEFI boot (BIOS GRUB may not be installed)
    local ovmf_code="${SCRIPT_DIR}/OVMF_CODE.fd"
    local ovmf_vars="${SCRIPT_DIR}/OVMF_VARS.fd"
    local ovmf_combined="${SCRIPT_DIR}/OVMF.fd"

    local uefi_args=""
    if [[ -f "${ovmf_code}" && -f "${ovmf_vars}" ]]; then
        # Use pflash drives (proper UEFI)
        # Copy VARS to a temp file so it can be written to
        local vars_copy="${SCRIPT_DIR}/OVMF_VARS_tmp.fd"
        cp "${ovmf_vars}" "${vars_copy}"
        uefi_args="-drive if=pflash,format=raw,readonly=on,file=${ovmf_code} -drive if=pflash,format=raw,file=${vars_copy}"
        log "Using UEFI firmware (pflash mode)"
    elif [[ -f "${ovmf_combined}" ]]; then
        uefi_args="-bios ${ovmf_combined}"
        log "Using UEFI firmware (combined mode)"
    else
        local ovmf
        ovmf=$(get_ovmf)
        if [[ -f "${ovmf}" ]]; then
            uefi_args="-bios ${ovmf}"
            log "Using UEFI firmware: ${ovmf}"
        else
            log "No UEFI firmware found, trying BIOS mode"
        fi
    fi

    "${QEMU}" \
        -drive "file=${img_path},format=raw,if=virtio" \
        ${uefi_args} \
        -m 2048 \
        -cpu qemu64 \
        -smp 2 \
        -net nic,model=virtio \
        -net user \
        -vga virtio \
        -display sdl \
        -serial stdio \
        -name "frOSt Desktop" \
        "$@"
}

# =============================================================================
# Test: Headless mode (for automated testing)
# =============================================================================
test_headless() {
    log "Test: Headless automated test..."

    local img_path="${IMAGE_FILE}"
    if [[ $IS_WSL -eq 1 ]]; then
        img_path="${IMAGE_FILE_WIN}"
    fi

    timeout 60 "${QEMU}" \
        -drive "file=${img_path},format=raw,if=virtio" \
        -m 1024 \
        -cpu qemu64 \
        -nographic \
        -serial mon:stdio \
        -no-reboot \
        -name "frOSt Headless Test" \
        "$@" || true
}

# =============================================================================
# Main
# =============================================================================
usage() {
    echo "frOSt Test Runner"
    echo ""
    echo "Usage: $0 [mode] [extra-qemu-args...]"
    echo ""
    echo "Modes:"
    echo "  bios       Boot in BIOS mode (default)"
    echo "  uefi       Boot in UEFI mode"
    echo "  usb        Simulate USB boot"
    echo "  desktop    Desktop mode (2GB RAM, virtio-vga)"
    echo "  headless   Headless test (60s timeout)"
    echo "  all        Run all tests sequentially"
    echo ""
    echo "Examples:"
    echo "  $0 bios"
    echo "  $0 uefi"
    echo "  $0 usb -m 2048"
}

main() {
    local mode="${1:-bios}"
    shift 2>/dev/null || true

    check_prereqs

    case "${mode}" in
        bios)     test_bios_boot "$@" ;;
        uefi)     test_uefi_boot "$@" ;;
        usb)      test_usb_mode "$@" ;;
        desktop)  test_desktop "$@" ;;
        headless) test_headless "$@" ;;
        all)
            test_headless "$@"
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown mode: ${mode}"
            usage
            exit 1
            ;;
    esac
}

main "$@"
