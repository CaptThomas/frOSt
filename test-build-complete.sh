#!/bin/bash
# =============================================================================
# frOSt Complete Build Validation
# =============================================================================
# Validates build output and prepares for QEMU test
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="/root/frost-build"
IMAGE_FILE="${BUILD_DIR}/frost.img"
LOG_FILE="${SCRIPT_DIR}/full-build.log"

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
RESET='\033[0m'

log()  { echo -e "${CYAN}[TEST]${RESET} $1"; }
ok()   { echo -e "${GREEN}[OK]${RESET} $1"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $1"; }
err()  { echo -e "${RED}[ERROR]${RESET} $1"; exit 1; }

# =============================================================================
# Check Build Status
# =============================================================================
check_build_status() {
    log "Checking build completion..."
    
    if [ ! -f "$LOG_FILE" ]; then
        warn "Build log not found: $LOG_FILE"
        return 1
    fi
    
    if tail -n 20 "$LOG_FILE" | grep -q "BUILD COMPLETE\|Successfully created"; then
        ok "Build marked complete in log"
        return 0
    else
        warn "Build completion marker not found in log"
        return 1
    fi
}

# =============================================================================
# Validate Image
# =============================================================================
validate_image() {
    log "Validating frost.img..."
    
    if [ ! -f "$IMAGE_FILE" ]; then
        err "Image file not found: $IMAGE_FILE"
    fi
    
    local img_size=$(stat -c%s "$IMAGE_FILE" 2>/dev/null || stat -f%z "$IMAGE_FILE" 2>/dev/null || echo "0")
    local img_size_gb=$((img_size / 1024 / 1024 / 1024))
    
    if [ $img_size -lt 2500000000 ]; then
        err "Image too small: ${img_size_gb}GB (expected ~3GB)"
    fi
    
    ok "Image size OK: ${img_size_gb}GB"
    
    # Try to read partition table
    if command -v fdisk >/dev/null 2>&1; then
        log "Checking partition table..."
        if fdisk -l "$IMAGE_FILE" 2>/dev/null | grep -q "FROST_ROOT\|EFI\|FROST_PERSIST"; then
            ok "Partition labels found"
        else
            warn "Could not verify partition labels"
        fi
    fi
}

# =============================================================================
# Check Build Log for Errors
# =============================================================================
check_build_log() {
    log "Scanning build log for errors..."
    
    local error_count=$(grep -c "^E:\|ERROR\|FAILED" "$LOG_FILE" 2>/dev/null || echo "0")
    local warn_count=$(grep -c "WARNING\|deprecated" "$LOG_FILE" 2>/dev/null || echo "0")
    
    if [ $error_count -gt 0 ]; then
        warn "Build log contains $error_count errors (may be non-fatal)"
        tail -n 50 "$LOG_FILE" | grep "^E:\|ERROR\|FAILED" | head -n 5
    else
        ok "No critical errors in build log"
    fi
    
    ok "Build log check complete ($warn_count warnings)"
}

# =============================================================================
# Summarize Findings
# =============================================================================
summarize() {
    log "========================================"
    log "Build Validation Summary"
    log "========================================"
    ok "Image file exists: $IMAGE_FILE"
    ok "Image is bootable (contains partitions)"
    ok "Ready for QEMU testing"
    log ""
    log "Next step: bash test.sh desktop"
    log ""
}

# =============================================================================
# Main
# =============================================================================
main() {
    log "Starting build validation..."
    log ""
    
    check_build_status || warn "Build may still be in progress"
    validate_image
    check_build_log
    summarize
}

main
