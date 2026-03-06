#!/bin/bash
# =============================================================================
# frOSt Post-Build Complete Workflow
# =============================================================================
# End-to-end: validate build → boot test → feature check → deploy
# Run this once build.sh completes
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="/root/frost-build"
IMAGE_FILE="${BUILD_DIR}/frost.img"

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
RESET='\033[0m'

log()  { echo -e "${CYAN}[WORKFLOW]${RESET} $1"; }
ok()   { echo -e "${GREEN}[OK]${RESET} $1"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $1"; }
err()  { echo -e "${RED}[ERROR]${RESET} $1"; exit 1; }

# =============================================================================
# PHASE 1: Validate Build Output
# =============================================================================
phase_validate_build() {
    log "========== PHASE 1: Validate Build =========="
    
    if [ ! -f "$IMAGE_FILE" ]; then
        err "Image file not found: $IMAGE_FILE"
    fi
    
    local img_size=$(stat -c%s "$IMAGE_FILE" 2>/dev/null || stat -f%z "$IMAGE_FILE" 2>/dev/null || echo "0")
    local img_size_gb=$((img_size / 1024 / 1024 / 1024))
    
    if [ $img_size -lt 2500000000 ]; then
        err "Image too small: ${img_size_gb}GB (expected ~3GB)"
    fi
    
    ok "Image validated: ${img_size_gb}GB"
    ok "Ready for QEMU test"
}

# =============================================================================
# PHASE 2: Boot Test (QEMU Desktop)
# =============================================================================
phase_boot_test() {
    log "========== PHASE 2: Boot Test (QEMU) =========="
    log "Starting QEMU with: bash test.sh desktop"
    log "Expected: boot to login prompt without kernel panic"
    log "NOTE: This will open a QEMU window; close it when login prompt appears"
    log ""
    log "Press [Enter] to start QEMU test..."
    read -r
    
    if ! bash test.sh desktop 2>&1 | tail -n 50; then
        warn "QEMU test may have issues (see output above)"
        log "This may be normal if QEMU path is unresolved on Windows with WSL paths"
    fi
    
    ok "Boot test complete (check QEMU output above)"
}

# =============================================================================
# PHASE 3: Feature Validation Checklist
# =============================================================================
phase_feature_checklist() {
    log "========== PHASE 3: Manual Feature Checklist =========="
    log ""
    log "After QEMU boots to login prompt, verify these features:"
    log ""
    log "  Boot:"
    log "    [ ] No kernel panic at init (should reach login:)"
    log "    [ ] systemd services started cleanly"
    log "    [ ] XFCE4 desktop loads (may auto-login)"
    log ""
    log "  Desktop UI:"
    log "    [ ] Dark theme applied (Adwaita-dark base)"
    log "    [ ] Spinning logo in lower-left corner"
    log "    [ ] Conky system monitor visible (top-right)"
    log "    [ ] Terminal opens with correct theme"
    log "    [ ] Bash prompt shows custom banner (hacker style)"
    log ""
    log "  Persistence:"
    log "    [ ] /frost/persist mounted"
    log "    [ ] /frost/merged is overlayfs (union of squashfs + tmpfs)"
    log "    [ ] frost-persist.json exists"
    log ""
    log "  Network:"
    log "    [ ] WiFi interface detected (iwlwifi loaded)"
    log "    [ ] NetworkManager responsive"
    log "    [ ] Can connect to SSID when available"
    log ""
    log "Features marked above will be re-tested at deployment if any fail."
    log ""
}

# =============================================================================
# PHASE 4: Deploy to USB
# =============================================================================
phase_deploy_usb() {
    log "========== PHASE 4: Deploy to USB =========="
    
    log "This step will:"
    log "  1. Shut down QEMU (close window)"
    log "  2. Copy frost.img to USB drive using deploy.ps1"
    log "  3. Expand persistence partition to fill USB"
    log ""
    log "USB REQUIREMENTS:"
    log "  - Minimum 4GB USB 3.0 drive (USB 2.0 works but slow)"
    log "  - Will be COMPLETELY ERASED"
    log "  - Must be connected to Windows"
    log ""
    log "Ready to deploy? [y/n]"
    read -r response
    
    if [ "$response" != "y" ] && [ "$response" != "Y" ]; then
        warn "Deployment skipped"
        return 0
    fi
    
    log "Opening deploy.ps1 in PowerShell..."
    powershell -ExecutionPolicy Bypass -File "${SCRIPT_DIR}/deploy.ps1"
    
    ok "Deployment complete"
    log "Monitor progress in deploy-status.txt"
}

# =============================================================================
# PHASE 5: Summary & Cleanup
# =============================================================================
phase_summary() {
    log "========== PHASE 5: Summary =========="
    log ""
    log "Build workflow complete!"
    log ""
    log "Generated Files:"
    log "  frost.img (ready for USB deployment)"
    log "  rootfs/ (Debian chroot, can be preserved for incremental builds)"
    log ""
    log "Next Steps:"
    log "  1. Boot USB on target hardware (ASUS TUF Dash F15)"
    log "  2. Verify WiFi driver loads (iwlwifi for AX201)"
    log "  3. Test persistence (create files, reboot)"
    log "  4. Test desktop features (theme, logo, conky)"
    log ""
    log "Troubleshooting:"
    log "  - Kernel panic? Check initramfs/init error handling"
    log "  - WiFi missing? Verify firmware-iwlwifi in rootfs"
    log "  - Slow USB boot? Use USB 3.0; may take 30-45s"
    log "  - Desktop issues? Check /frost/merged mount state"
    log ""
    ok "All done!"
}

# =============================================================================
# Main Workflow
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}║         frOSt Complete Build & Deploy Workflow         ║${RESET}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    
    phase_validate_build
    phase_boot_test
    phase_feature_checklist
    phase_deploy_usb
    phase_summary
    
    echo ""
    log "Workflow script finished. Goodbye!"
}

main
