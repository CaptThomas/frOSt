# Fix USB disk and redeploy
$ErrorActionPreference = "Stop"

# Check if elevated
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Elevating to admin..."
    Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

Write-Host "=== Fixing USB disk ==="

# Try diskpart to bring disk online
$dpScript = @"
select disk 1
online disk
attributes disk clear readonly
"@
$dpScript | Out-File "$env:TEMP\frost-fix.txt" -Encoding ASCII
$dpOut = & diskpart /s "$env:TEMP\frost-fix.txt" 2>&1 | Out-String
Write-Host "Diskpart: $dpOut"

Start-Sleep -Seconds 2

# Check disk status
$disk = Get-Disk -Number 1
Write-Host "Disk Status: $($disk.OperationalStatus)"
Write-Host "Disk Size: $($disk.Size)"
Write-Host "Disk Name: $($disk.FriendlyName)"

if ($disk.Size -eq 0) {
    Write-Host ""
    Write-Host "USB disk still shows 0 bytes. Trying to rescan..."

    # Rescan
    $dpScript2 = "rescan"
    $dpScript2 | Out-File "$env:TEMP\frost-rescan.txt" -Encoding ASCII
    & diskpart /s "$env:TEMP\frost-rescan.txt" 2>&1 | Out-String

    Start-Sleep -Seconds 3

    $disk = Get-Disk -Number 1
    Write-Host "After rescan - Size: $($disk.Size), Status: $($disk.OperationalStatus)"
}

if ($disk.Size -gt 0) {
    Write-Host ""
    Write-Host "=== USB disk recovered! Deploying image... ==="

    # Run the deploy script
    & powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\thoma\Documents\frOSt\deploy-usb.ps1" -DiskNumber 1 -Yes
} else {
    Write-Host ""
    Write-Host "ERROR: USB disk still shows 0 bytes."
    Write-Host "Please physically disconnect and reconnect the USB drive, then run deploy-usb.ps1 again."
}

Write-Host ""
Write-Host "Done. Press Enter to close."
Read-Host
