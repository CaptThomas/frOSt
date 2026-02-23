# =============================================================================
# frOSt USB Deploy Script (PowerShell)
# =============================================================================
# Writes the frOSt disk image to a USB drive.
# Auto-elevates to Administrator if needed.
#
# Usage:
#   Right-click -> Run with PowerShell (as Admin)
#   Or: powershell -ExecutionPolicy Bypass -File deploy-usb.ps1
#
# Options:
#   -DiskNumber N   Target physical disk number (auto-detects USB if omitted)
#   -Yes            Skip confirmation prompt
#   -ImagePath      Path to frost.img (copies from WSL if not specified)
# =============================================================================

param(
    [int]$DiskNumber = -1,
    [switch]$Yes,
    [string]$ImagePath = "",
    [string]$WslImage = "/root/frost-build/frost.img"
)

$ErrorActionPreference = "Stop"
$LogFile = Join-Path $PSScriptRoot "deploy.log"

function Log($msg) {
    $line = "[frOSt-deploy] $msg"
    Write-Host $line -ForegroundColor Cyan
    $line | Out-File $LogFile -Append -Encoding UTF8
}
function Ok($msg) {
    $line = "[OK] $msg"
    Write-Host $line -ForegroundColor Green
    $line | Out-File $LogFile -Append -Encoding UTF8
}
function Warn($msg) {
    $line = "[WARN] $msg"
    Write-Host $line -ForegroundColor Yellow
    $line | Out-File $LogFile -Append -Encoding UTF8
}
function Err($msg) {
    $line = "[ERROR] $msg"
    Write-Host $line -ForegroundColor Red
    $line | Out-File $LogFile -Append -Encoding UTF8
    Read-Host "Press Enter to exit"
    exit 1
}

# Clear log
"frOSt Deploy - $(Get-Date)" | Out-File $LogFile -Encoding UTF8

# Banner
Write-Host ""
Write-Host "  __       ___  ____  _   " -ForegroundColor Cyan
Write-Host " / _|_ __ / _ \/ ___|| |_ " -ForegroundColor Cyan
Write-Host "| |_| |__| | | \___ \| __|" -ForegroundColor Cyan
Write-Host "|  _| |  | |_| |___) | |_ " -ForegroundColor Cyan
Write-Host "|_| |_|   \___/|____/ \__|" -ForegroundColor Cyan
Write-Host ""
Write-Host "frOSt USB Deploy Tool" -ForegroundColor White
Write-Host "=================================" -ForegroundColor White
Write-Host ""

# === Check admin ===
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Log "Requesting Administrator privileges..."
    $argList = "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($DiskNumber -ge 0) { $argList += " -DiskNumber $DiskNumber" }
    if ($Yes) { $argList += " -Yes" }
    if ($ImagePath) { $argList += " -ImagePath `"$ImagePath`"" }
    if ($WslImage -ne "/root/frost-build/frost.img") { $argList += " -WslImage `"$WslImage`"" }
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -Wait
    } catch {
        Err "Administrator privileges required. Please right-click and 'Run as Administrator'."
    }
    exit
}

Ok "Running as Administrator"

# === Find/prepare image ===
Log "Checking image..."

if ($ImagePath -and (Test-Path $ImagePath)) {
    $imgFile = $ImagePath
} else {
    # Try common locations
    $candidates = @(
        (Join-Path $PSScriptRoot "frost.img"),
        (Join-Path $env:USERPROFILE "frost.img"),
        "C:\frost.img"
    )
    $imgFile = ""
    foreach ($c in $candidates) {
        if (Test-Path $c) {
            $imgFile = $c
            break
        }
    }

    if (-not $imgFile) {
        # Copy from WSL
        Log "Copying image from WSL..."
        $imgFile = Join-Path $env:USERPROFILE "frost.img"
        try {
            $testWsl = wsl -d Ubuntu -u root -- echo "ok" 2>&1
            if ($testWsl -ne "ok") { throw "WSL not available" }
            wsl -d Ubuntu -u root -- bash -c "test -f '$WslImage' || exit 1" 2>&1
            if ($LASTEXITCODE -ne 0) {
                Err "Image not found: $WslImage`nRun 'sudo bash build.sh' in WSL first."
            }
            Log "Copying from WSL (this may take a few minutes for large images)..."
            wsl -d Ubuntu -u root -- bash -c "cp '$WslImage' '/mnt/c/Users/$env:USERNAME/frost.img'" 2>&1
            if (-not (Test-Path $imgFile)) {
                Err "Failed to copy image from WSL."
            }
        } catch {
            Err "Could not find or copy frost.img. Build with 'sudo bash build.sh' in WSL, then copy to:`n  $imgFile"
        }
    }
}

$imgSize = (Get-Item $imgFile).Length
$imgMB = [math]::Round($imgSize / 1MB)
Ok "Image: $imgFile ($imgMB MB)"

# === Find USB drives ===
Log "Scanning for USB drives..."
$usbDisks = @(Get-Disk | Where-Object { $_.BusType -eq "USB" })

if ($usbDisks.Count -eq 0) {
    Err "No USB drives found. Insert a USB drive and try again."
}

# Select disk
if ($DiskNumber -ge 0) {
    $targetDisk = $usbDisks | Where-Object { $_.Number -eq $DiskNumber }
    if (-not $targetDisk) {
        $available = ($usbDisks | ForEach-Object { "Disk $($_.Number): $($_.FriendlyName.Trim()) ($([math]::Round($_.Size/1GB)) GB)" }) -join "; "
        Err "Disk $DiskNumber is not a USB drive. Available: $available"
    }
} elseif ($usbDisks.Count -eq 1) {
    $targetDisk = $usbDisks[0]
} else {
    Write-Host "Multiple USB drives found:" -ForegroundColor Yellow
    foreach ($d in $usbDisks) {
        Write-Host "  Disk $($d.Number): $($d.FriendlyName.Trim()) ($([math]::Round($d.Size/1GB)) GB)"
    }
    $DiskNumber = [int](Read-Host "Enter disk number")
    $targetDisk = $usbDisks | Where-Object { $_.Number -eq $DiskNumber }
    if (-not $targetDisk) { Err "Invalid disk number." }
}

$diskNum = $targetDisk.Number
$diskName = $targetDisk.FriendlyName.Trim()
$diskGB = [math]::Round($targetDisk.Size / 1GB)
$diskSizeBytes = $targetDisk.Size

Log "Target: Disk $diskNum - $diskName ($diskGB GB)"

# Check image fits
if ($imgSize -gt $diskSizeBytes) {
    Err "Image ($imgMB MB) is larger than USB drive ($diskGB GB)."
}

# === Confirm ===
Write-Host ""
Write-Host "  ======================================================" -ForegroundColor Red
Write-Host "    WARNING: ALL DATA ON DISK $diskNum WILL BE DESTROYED" -ForegroundColor Red
Write-Host "  ======================================================" -ForegroundColor Red
Write-Host "  Target: $diskName ($diskGB GB)" -ForegroundColor White
Write-Host "  Source: $imgFile ($imgMB MB)" -ForegroundColor White
Write-Host ""

if (-not $Yes) {
    $confirm = Read-Host "  Type 'yes' to continue"
    if ($confirm -ne "yes") { Err "Aborted by user." }
}

# === Prepare disk ===
Log "Preparing USB drive..."

# Dismount all volumes so Windows releases the disk
Get-Partition -DiskNumber $diskNum -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.DriveLetter) {
        Log "Removing drive letter $($_.DriveLetter)..."
        try {
            Remove-PartitionAccessPath -DiskNumber $diskNum -PartitionNumber $_.PartitionNumber -AccessPath "$($_.DriveLetter):\" -ErrorAction SilentlyContinue
        } catch { }
    }
}

# Clean disk to release Windows' lock on partition volumes
Log "Cleaning disk to release volume locks..."
"select disk $diskNum`nclean" | Out-File "$env:TEMP\frost-dp.txt" -Encoding ASCII
$dpOut = diskpart /s "$env:TEMP\frost-dp.txt" 2>&1
"Diskpart clean: $dpOut" | Out-File $LogFile -Append -Encoding UTF8
Start-Sleep 2

# === Write image directly using .NET raw disk I/O ===
Log "Writing frOSt image to USB ($imgMB MB)..."
Log "This may take several minutes - do not disconnect the USB..."
Write-Host ""

$diskPath = "\\.\PHYSICALDRIVE$diskNum"
$bufferSize = 4 * 1024 * 1024  # 4MB blocks

try {
    $source = [System.IO.File]::OpenRead($imgFile)
    # Open physical disk for writing (requires admin)
    $dest = [System.IO.FileStream]::new(
        $diskPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::ReadWrite,
        $bufferSize
    )

    $buffer = New-Object byte[] $bufferSize
    $totalBytes = $source.Length
    $written = [long]0
    $startTime = Get-Date
    $lastReport = Get-Date

    while (($bytesRead = $source.Read($buffer, 0, $bufferSize)) -gt 0) {
        $dest.Write($buffer, 0, $bytesRead)
        $written += $bytesRead

        # Progress report every 2 seconds
        $now = Get-Date
        if (($now - $lastReport).TotalSeconds -ge 2) {
            $pct = [math]::Round($written * 100 / $totalBytes, 1)
            $elapsed = ($now - $startTime).TotalSeconds
            $speed = [math]::Round($written / 1MB / $elapsed, 1)
            $remaining = if ($speed -gt 0) { [math]::Round(($totalBytes - $written) / 1MB / $speed) } else { 0 }
            Write-Host "`r  $([math]::Round($written/1MB)) / $imgMB MB ($pct%) - ${speed} MB/s - ~${remaining}s remaining   " -NoNewline -ForegroundColor Yellow
            $lastReport = $now
        }
    }

    $dest.Flush()
    $dest.Close()
    $source.Close()

    Write-Host ""
    $totalTime = [math]::Round(((Get-Date) - $startTime).TotalSeconds)
    $avgSpeed = [math]::Round($imgMB / [math]::Max($totalTime, 1), 1)
    Ok "Image written successfully ($totalTime seconds, ${avgSpeed} MB/s average)"
} catch {
    if ($source) { $source.Close() }
    if ($dest) { $dest.Close() }
    Err "Failed to write image: $_"
}

# Note: Persistence partition expansion happens automatically on first boot
# via the frost-expand-persist systemd service. No need to expand here.
Ok "Persistence partition will auto-expand on first boot"

# === Bring disk online ===
Log "Bringing disk online..."
Start-Sleep 2
try {
    Set-Disk -Number $diskNum -IsOffline $false -ErrorAction SilentlyContinue
} catch { }

# Try diskpart as fallback
"select disk $diskNum`nonline disk`nattributes disk clear readonly" | Out-File "$env:TEMP\frost-dp.txt" -Encoding ASCII
diskpart /s "$env:TEMP\frost-dp.txt" 2>&1 | Out-Null

Start-Sleep 2

# Check result
$finalDisk = Get-Disk -Number $diskNum
$finalParts = (Get-Partition -DiskNumber $diskNum -ErrorAction SilentlyContinue | Measure-Object).Count
Log "Final state: $($finalDisk.OperationalStatus), $finalParts partitions"

Ok "USB drive ready"

# === Done ===
Write-Host ""
Write-Host "  ======================================================" -ForegroundColor Green
Write-Host "    frOSt deployed successfully to USB!" -ForegroundColor Green
Write-Host "  ======================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Persistence partition will auto-expand on first boot." -ForegroundColor White
Write-Host ""
Write-Host "  To boot on real hardware:" -ForegroundColor White
Write-Host "    1. Insert USB into target machine" -ForegroundColor White
Write-Host "    2. Enter BIOS/UEFI boot menu (F12/F2/DEL)" -ForegroundColor White
Write-Host "    3. Select USB drive" -ForegroundColor White
Write-Host "    4. Choose 'frOSt Desktop' from GRUB menu" -ForegroundColor White
Write-Host ""
Write-Host "  Default login: frost / frost" -ForegroundColor White
Write-Host ""
Write-Host "  Full log: $LogFile" -ForegroundColor Gray
Write-Host ""

Read-Host "Press Enter to exit"
