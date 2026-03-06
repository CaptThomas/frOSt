#!/bin/bash
# =============================================================================
# frOSt Complete Feature Validation Test
# =============================================================================
# Comprehensive test of all features after QEMU boot to login prompt
# Run this INSIDE the booted frOSt system via QEMU
# =============================================================================

set -euo pipefail

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
RESET='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

test_header() {
    echo ""
    echo -e "${CYAN}========================================${RESET}"
    echo -e "${CYAN}$1${RESET}"
    echo -e "${CYAN}========================================${RESET}"
}

test_ok() {
    echo -e "${GREEN}[PASS]${RESET} $1"
    ((TESTS_PASSED++))
}

test_fail() {
    echo -e "${RED}[FAIL]${RESET} $1"
    ((TESTS_FAILED++))
}

test_warn() {
    echo -e "${YELLOW}[WARN]${RESET} $1"
}

# =============================================================================
# Boot Environment
# =============================================================================
test_header "BOOT ENVIRONMENT"

if [ -f /etc/os-release ]; then
    . /etc/os-release
    test_ok "OS Release: $ID $VERSION_ID"
else
    test_fail "OS Release file not found"
fi

if systemctl is-system-running >/dev/null 2>&1; then
    status=$(systemctl is-system-running)
    test_ok "Systemd running: $status"
else
    test_fail "Systemd not responding"
fi

# =============================================================================
# Overlay & Persistence
# =============================================================================
test_header "OVERLAY & PERSISTENCE"

if [ -d /frost/lower ] && [ -d /frost/upper ]; then
    test_ok "Overlay directories present"
else
    test_fail "Overlay directories missing"
fi

if mountpoint -q /frost/merged; then
    test_ok "Overlay filesystem mounted at /frost/merged"
else
    test_fail "/frost/merged not mounted"
fi

if [ -d /frost/persist ]; then
    test_ok "Persistence partition mounted"
    if [ -f /frost/persist/frost-persist.json ]; then
        test_ok "Persistence config found"
    else
        test_warn "Persistence config not found (expected on first boot)"
    fi
else
    test_fail "Persistence partition not mounted"
fi

# =============================================================================
# Desktop Environment
# =============================================================================
test_header "DESKTOP ENVIRONMENT"

if systemctl is-active --quiet lightdm; then
    test_ok "LightDM running"
else
    test_warn "LightDM not active (may be normal in text-only boot)"
fi

if command -v xfce4-session >/dev/null 2>&1; then
    test_ok "XFCE4 installed"
else
    test_warn "XFCE4 not found"
fi

if [ -f /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml ]; then
    test_ok "XFCE4 config found"
else
    test_warn "XFCE4 config not found"
fi

# =============================================================================
# Theming & UI
# =============================================================================
test_header "THEMING & UI"

if [ -f /root/.config/gtk-3.0/gtk.css ] || [ -f ~/.config/gtk-3.0/gtk.css ]; then
    test_ok "GTK3 theme CSS found"
else
    test_warn "GTK3 theme CSS not found (will apply defaults)"
fi

if [ -f /usr/share/pixmaps/spinning-logo.png ] || [ -f /usr/local/share/pixmaps/spinning-logo.png ]; then
    test_ok "Spinning logo image found"
else
    test_warn "Spinning logo image not found"
fi

if [ -f /usr/local/bin/frost-start-logo.sh ]; then
    test_ok "Logo startup script found"
else
    test_warn "Logo startup script not found"
fi

# =============================================================================
# System Tools
# =============================================================================
test_header "SYSTEM TOOLS"

tools=(
    "firefox"
    "xfce4-terminal"
    "htop"
    "neofetch"
    "conky"
    "python3"
    "wget"
    "curl"
    "git"
    "gnome-terminal"
)

for tool in "${tools[@]}"; do
    if command -v "$tool" >/dev/null 2>&1; then
        test_ok "Tool found: $tool"
    else
        test_warn "Tool missing: $tool (optional)"
    fi
done

# =============================================================================
# Network
# =============================================================================
test_header "NETWORK"

if systemctl is-active --quiet NetworkManager; then
    test_ok "NetworkManager active"
else
    test_warn "NetworkManager not active"
fi

if ip link show 2>/dev/null | grep -q "wlan0\|wlp"; then
    test_ok "WiFi interface detected"
    
    if rfkill list wifi | grep -q "Soft blocked: no"; then
        test_ok "WiFi not soft-blocked"
    else
        test_warn "WiFi may be soft-blocked"
    fi
else
    test_warn "WiFi interface not found (may need module load)"
fi

if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    test_ok "Network connectivity (external)"
else
    test_warn "No external network connectivity (expected on isolated systems)"
fi

# =============================================================================
# Persistence CLI Tools
# =============================================================================
test_header "PERSISTENCE CLI TOOLS"

cli_tools=(
    "/usr/local/bin/frost-persist"
    "/usr/local/bin/frost-config"
    "/usr/local/bin/frost-overlay"
    "/usr/local/bin/frost-expand-persist"
)

for tool in "${cli_tools[@]}"; do
    if [ -x "$tool" ]; then
        test_ok "CLI tool: $(basename $tool)"
    else
        test_warn "CLI tool missing: $(basename $tool)"
    fi
done

# =============================================================================
# Summary
# =============================================================================
test_header "TEST SUMMARY"

TOTAL=$((TESTS_PASSED + TESTS_FAILED))
echo -e "${GREEN}Passed: $TESTS_PASSED${RESET}"
echo -e "${RED}Failed: $TESTS_FAILED${RESET}"
echo "Total:  $TOTAL"

if [ $TESTS_FAILED -eq 0 ]; then
    echo ""
    echo -e "${GREEN}All critical tests passed!${RESET}"
    exit 0
else
    echo ""
    echo -e "${YELLOW}Some tests failed or warnings detected.${RESET}"
    exit 1
fi
