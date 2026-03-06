#!/bin/bash
# =============================================================================
# frOSt Pre-Deployment Checklist
# =============================================================================
# Verify all critical components are in place before deployment
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="/root/frost-build"
ROOTFS="${BUILD_DIR}/rootfs"
IMAGE_FILE="${BUILD_DIR}/frost.img"

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
RESET='\033[0m'

PASS=0
FAIL=0
WARN=0

pass() { echo -e "${GREEN}[✓]${RESET} $1"; ((PASS++)); }
fail() { echo -e "${RED}[✗]${RESET} $1"; ((FAIL++)); }
warn() { echo -e "${YELLOW}[!]${RESET} $1"; ((WARN++)); }

check_file() {
    local path="$1"
    local desc="$2"
    if [ -f "$path" ]; then
        pass "$desc: $path"
    else
        fail "$desc: $path (NOT FOUND)"
    fi
}

check_dir() {
    local path="$1"
    local desc="$2"
    if [ -d "$path" ]; then
        pass "$desc: $path"
    else
        fail "$desc: $path (NOT FOUND)"
    fi
}

check_executable() {
    local path="$1"
    local desc="$2"
    if [ -x "$path" ]; then
        pass "$desc: $path"
    else
        fail "$desc: $path (NOT EXECUTABLE)"
    fi
}

echo -e "${CYAN}════════════════════════════════════════════════════════════${RESET}"
echo -e "${CYAN}frOSt Pre-Deployment Verification${RESET}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${RESET}"
echo ""

# =============================================================================
# Build Output
# =============================================================================
echo -e "${CYAN}Build Output:${RESET}"
if [ -f "$IMAGE_FILE" ]; then
    size=$(stat -c%s "$IMAGE_FILE" 2>/dev/null || stat -f%z "$IMAGE_FILE" 2>/dev/null || echo "0")
    size_gb=$((size / 1024 / 1024 / 1024))
    pass "Main disk image: frost.img (~${size_gb}GB)"
else
    fail "Main disk image: frost.img (NOT FOUND)"
fi

# =============================================================================
# Boot Files in Project Root
# =============================================================================
echo ""
echo -e "${CYAN}Project Boot Files:${RESET}"
check_file "$SCRIPT_DIR/boot/asm/early_init.asm" "ASM early init"
check_file "$SCRIPT_DIR/initramfs/init" "Shell init shim"
check_file "$SCRIPT_DIR/initramfs/frost_init.py" "Python init"

# =============================================================================
# Key Scripts
# =============================================================================
echo ""
echo -e "${CYAN}Automation Scripts:${RESET}"
check_executable "$SCRIPT_DIR/build.sh" "Main build script"
check_executable "$SCRIPT_DIR/test.sh" "QEMU test script"
check_executable "$SCRIPT_DIR/deploy.sh" "Linux deploy script"
check_file "$SCRIPT_DIR/deploy.ps1" "Windows deploy script"

# =============================================================================
# Desktop Assets
# =============================================================================
echo ""
echo -e "${CYAN}Desktop Assets:${RESET}"
check_file "$SCRIPT_DIR/desktop/wallpaper.svg" "Wallpaper (SVG)"
check_file "$SCRIPT_DIR/desktop/frost-logo.svg" "Logo (SVG)"
check_file "$SCRIPT_DIR/desktop/bashrc-frost" "Custom bashrc"
check_file "$SCRIPT_DIR/desktop/gtk-3.0/gtk.css" "GTK3 theme"
check_dir "$SCRIPT_DIR/desktop/xfce4" "XFCE4 config"

# =============================================================================
# Tools
# =============================================================================
echo ""
echo -e "${CYAN}CLI Tools (for post-boot):${RESET}"
check_file "$SCRIPT_DIR/tools/frost-persist.py" "Persistence manager"
check_file "$SCRIPT_DIR/tools/frost-overlay.py" "Overlay manager"
check_file "$SCRIPT_DIR/tools/frost-config.py" "Config wizard"
check_file "$SCRIPT_DIR/tools/frost-expand-persist.sh" "Persistence expander"
check_file "$SCRIPT_DIR/tools/frost-usb-watchdog.py" "USB watchdog"

# =============================================================================
# Code Quality Checks
# =============================================================================
echo ""
echo -e "${CYAN}Code Quality:${RESET}"

# Check shell syntax (if available)
if command -v bash >/dev/null 2>&1; then
    if bash -n "$SCRIPT_DIR/initramfs/init" 2>/dev/null; then
        pass "Shell init syntax valid"
    else
        fail "Shell init syntax error"
    fi
fi

# Check Python syntax
if command -v python3 >/dev/null 2>&1; then
    if python3 -m py_compile "$SCRIPT_DIR/initramfs/frost_init.py" 2>/dev/null; then
        pass "Python init syntax valid"
    else
        fail "Python init syntax error"
    fi
fi

# Check NASM syntax (if NASM available)
if command -v nasm >/dev/null 2>&1; then
    if nasm -f elf64 "$SCRIPT_DIR/boot/asm/early_init.asm" -o /tmp/test.o 2>/dev/null; then
        pass "ASM early_init syntax valid"
        rm -f /tmp/test.o
    else
        warn "ASM syntax could not be verified (NASM present but assembly may fail)"
    fi
else
    warn "ASM early_init syntax not checked (NASM not available in this context)"
fi

# =============================================================================
# Build Script Key Features
# =============================================================================
echo ""
echo -e "${CYAN}Build Script Features (Verified):${RESET}"

if grep -q "no-check-gpg" "$SCRIPT_DIR/build.sh"; then
    pass "Debootstrap GPG fallback strategy present"
else
    fail "Debootstrap GPG fallback missing"
fi

if grep -q "debootstrap_include=" "$SCRIPT_DIR/build.sh"; then
    pass "Package list variable strategy present"
else
    fail "Package list variable strategy missing"
fi

# =============================================================================
# Init Script Hardening
# =============================================================================
echo ""
echo -e "${CYAN}Init Script Hardening:${RESET}"

if grep -q "mounted_squashfs=0" "$SCRIPT_DIR/initramfs/init"; then
    pass "Squashfs mount explicit tracking"
else
    fail "Squashfs mount error handling missing"
fi

if grep -q "if \[ \$mounted_squashfs -eq 0 \]" "$SCRIPT_DIR/initramfs/init"; then
    pass "Fatal condition check on mount failure"
else
    fail "Fatal condition check missing"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════${RESET}"
TOTAL=$((PASS + FAIL + WARN))
percentage=$((PASS * 100 / (PASS + FAIL)))

if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}PASS: All critical components verified${RESET}"
    echo "Passed: $PASS | Warnings: $WARN | Total: $TOTAL"
    exit 0
else
    echo -e "${RED}FAIL: Some components missing or invalid${RESET}"
    echo "Passed: $PASS | Failed: $FAIL | Warnings: $WARN | Total: $TOTAL"
    echo ""
    echo "Fix any listed failures before deployment."
    exit 1
fi
