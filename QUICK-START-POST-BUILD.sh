#!/bin/bash
# =============================================================================
# frOSt: Steps to Take When Build.sh Completes
# =============================================================================
# Quick reference for post-build actions
# =============================================================================

cat << 'EOF'
╔════════════════════════════════════════════════════════════════╗
║         frOSt Build Completion Action Plan                     ║
╚════════════════════════════════════════════════════════════════╝

WHEN: build.sh completes (watch for build 739c1009 exit code)

STEP 1: Verify Image
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ls -lh /root/frost-build/frost.img
  Expected: ~3GB file created
  
  Run: bash pre-deploy-checklist.sh
  Expected: All checks pass

STEP 2: Boot Test in QEMU
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  bash test.sh desktop
  
  Expected behavior:
    ✓ QEMU window opens
    ✓ Boot messages appear
    ✓ XFCE4 desktop loads (or login prompt if headless)
    ✓ NO "kernel panic" message
    ✓ Spinning logo visible (lower-left corner)
    ✓ Conky system monitor (top-right)
  
  If all above: SUCCESS ✓
  If kernel panic: Review initramfs/init error messages in serial log
  If desktop issues: May be normal in QEMU; test on real hardware

STEP 3: USB Deployment
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  powershell -ExecutionPolicy Bypass -File deploy.ps1
  
  What happens:
    1. Will prompt for admin elevation
    2. Will display list of USB drives
    3. Will ask for confirmation (default: disk 1)
    4. Will write frost.img to USB
    5. Will expand persistence partition to fill USB
    6. Will display completion status
  
  Time: ~5-10 minutes depending on USB speed

STEP 4: Test on Hardware (Optional)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  1. INSERT USB into target machine (ASUS TUF Dash F15)
  2. BOOT from USB (F2 → Boot → USB Drive)
  3. SELECT "frOSt Desktop" from GRUB menu
  4. WAIT for systemd → LightDM → auto-login
  5. VERIFY:
     ✓ Desktop loads without freeze
     ✓ Spinning logo visible
     ✓ Can open Firefox
     ✓ Firefox can reach google.com (WiFi test)
     ✓ Can mkdir /home/frost/test-persist && reboot
     ✓ After reboot, /home/frost/test-persist/ still exists

STEP 5: Final Cleanup (Optional)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  rm -f /root/frost-build/frost.img  [keeps build for next time]
  rm -f deploy-status.txt
  rm -f full-build.log
  
  [Or: keep everything for future incremental rebuilds]

TIMELINE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Build completion:    ETA ~1-2 hours from now
  QEMU test:           ~5 minutes
  Deploy to USB:       ~5-10 minutes
  Hardware test:       ~10 minutes
  
  Total remaining:     ~1.5-2.5 hours

TROUBLESHOOTING
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Kernel Panic at pid 1?
    → Check initramfs/init mount logic
    → Verify squashfs is valid (not corrupted)
    → Review dmesg for mount errors

  QEMU doesn't find image?
    → Run `bash test.sh desktop` (auto-converts paths)
    → May need to copy frost.img to WSL native path first

  USB deploy fails?
    → Verify USB is connected and detected
    → Check deploy-status.txt for error details
    → May need to manually unmount USB first: `Get-Partition -DriveLetter D | Remove-Partition`

  WiFi missing on hardware?
    → Boot to console (GRUB → frOSt Console)
    → Run `dmesg | grep -i iwl` to check firmware load
    → Run `rfkill list` to check soft-block state
    → Run `systemctl status frost-hwdetect` to check driver loading

DOCUMENTATION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  SESSION-SUMMARY.md      - Full build context & objectives
  .github/copilot-instructions.md  - Architecture & known pitfalls
  full-build.log          - Complete build output (for debugging)

EOF
