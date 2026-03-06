# =============================================================================
# frOSt: Full Rebuild + Deploy (Windows PowerShell)
# =============================================================================
# 1. Runs build.sh in WSL as root (full OS rebuild)
# 2. Deploys frost.img to USB via deploy.ps1
#
# Usage: Right-click > Run with PowerShell, or:
#   powershell -ExecutionPolicy Bypass -File rebuild-and-deploy.ps1
# =============================================================================

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$statusFile = Join-Path $scriptDir "rebuild-deploy-status.txt"

# Colors
function Write-Frost  { param($msg) Write-Host "[frOSt] $msg" -ForegroundColor Cyan }
function Write-Ok     { param($msg) Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Err    { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Write-Warn   { param($msg) Write-Host "[WARN] $msg" -ForegroundColor Yellow }

Write-Host ""
Write-Host "  :::::::::: :::::::::   ::::::::   ::::::::  ::::::::::" -ForegroundColor Cyan
Write-Host "  :+:        :+:    :+: :+:    :+: :+:    :+:    :+:   " -ForegroundColor Cyan
Write-Host "  +:+        +:+    +:+ +:+    +:+ +:+           +:+   " -ForegroundColor Cyan
Write-Host "  :#::+::#   +#++:++#:  +#+    +:+ +#++:++#++    +#+   " -ForegroundColor Cyan
Write-Host "  +#+        +#+    +#+ +#+    +#+        +#+    +#+    " -ForegroundColor Cyan
Write-Host "  #+#        #+#    #+# #+#    #+# #+#    #+#    #+#    " -ForegroundColor Cyan
Write-Host "  ###        ###    ###  ########   ########     ###    " -ForegroundColor Cyan
Write-Host ""
Write-Host "  Rebuild + Deploy Pipeline" -ForegroundColor White
Write-Host "  =========================" -ForegroundColor DarkGray
Write-Host ""

$startTime = Get-Date

# ─── Step 1: Verify WSL Ubuntu is available ──────────────────────────────────
Write-Frost "Checking WSL Ubuntu distro..."
try {
    # WSL outputs UTF-16 with embedded nulls; strip them for reliable matching
    $wslRaw = wsl --list --quiet 2>&1 | Out-String
    $wslClean = $wslRaw -replace '\x00', ''
    if ($wslClean -notmatch 'Ubuntu') { throw "Ubuntu distro not found in WSL" }
    # Make sure it starts
    wsl -d Ubuntu -u root -- echo ok 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Ubuntu distro failed to start" }
    Write-Ok "WSL Ubuntu available"
} catch {
    Write-Err "WSL Ubuntu distro is not installed or not running. Cannot build."
    Write-Err "Install with: wsl --install -d Ubuntu"
    "FAILED: WSL Ubuntu not available" | Out-File $statusFile -Encoding UTF8
    exit 1
}

# ─── Step 2: Run build.sh in WSL ─────────────────────────────────────────────
Write-Frost "Starting full rebuild in WSL (this will take a while)..."
"BUILD_STARTED $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File $statusFile -Encoding UTF8

$wslSrcPath = "/mnt/c/Users/thoma/Documents/frOSt"
$buildCmd = "cd '$wslSrcPath' && bash build.sh"

# Run build as root in WSL Ubuntu (not docker-desktop), streaming output
$buildProc = Start-Process -FilePath "wsl" `
    -ArgumentList "-d", "Ubuntu", "-u", "root", "--", "bash", "-c", $buildCmd `
    -NoNewWindow -PassThru -Wait

if ($buildProc.ExitCode -ne 0) {
    Write-Err "Build failed with exit code $($buildProc.ExitCode)"
    "BUILD_FAILED exit=$($buildProc.ExitCode) $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File $statusFile -Encoding UTF8
    exit 1
}

$buildElapsed = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
Write-Ok "Build completed in $buildElapsed minutes"
"BUILD_COMPLETE $buildElapsed min" | Out-File $statusFile -Encoding UTF8

# ─── Step 3: Verify image exists ─────────────────────────────────────────────
$imgFile = Join-Path $scriptDir "frost.img"
if (-not (Test-Path $imgFile)) {
    Write-Err "frost.img not found after build. Expected at: $imgFile"
    "FAILED: frost.img not found after build" | Out-File $statusFile -Encoding UTF8
    exit 1
}

$imgSize = [math]::Round((Get-Item $imgFile).Length / 1MB)
Write-Ok "frost.img found ($imgSize MB)"

# ─── Step 4: Prompt for deploy ───────────────────────────────────────────────
Write-Host ""
Write-Frost "Build complete. Ready to deploy to USB."
Write-Warn "Make sure your USB drive is plugged in (targets Disk 1)."
Write-Host ""
$confirm = Read-Host "Deploy to USB now? (y/N)"

if ($confirm -ne 'y' -and $confirm -ne 'Y') {
    Write-Frost "Deploy skipped. You can deploy later with:"
    Write-Host "  powershell -ExecutionPolicy Bypass -File deploy.ps1" -ForegroundColor DarkGray
    "BUILD_ONLY $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File $statusFile -Encoding UTF8
    exit 0
}

# ─── Step 5: Run deploy.ps1 ──────────────────────────────────────────────────
Write-Frost "Launching deploy..."
$deployScript = Join-Path $scriptDir "deploy.ps1"

if (-not (Test-Path $deployScript)) {
    Write-Err "deploy.ps1 not found at: $deployScript"
    "FAILED: deploy.ps1 not found" | Out-File $statusFile -Encoding UTF8
    exit 1
}

# deploy.ps1 auto-elevates, so just invoke it
& powershell -ExecutionPolicy Bypass -File $deployScript

$totalElapsed = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)

Write-Host ""
Write-Host "================================================" -ForegroundColor Green
Write-Host " frOSt rebuild + deploy complete!" -ForegroundColor Green
Write-Host " Total time: $totalElapsed minutes" -ForegroundColor Green
Write-Host "================================================" -ForegroundColor Green

"COMPLETE $totalElapsed min $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File $statusFile -Encoding UTF8
