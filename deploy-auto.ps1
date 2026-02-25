$ErrorActionPreference = "Stop"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Elevating to admin..."
    Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

Write-Host "=== frOSt Deploy (automated) ===" -ForegroundColor Cyan

$imgFile = "C:\Users\thoma\Documents\frOSt\frost.img"
if (-not (Test-Path $imgFile)) {
    Write-Host "ERROR: frost.img not found at $imgFile" -ForegroundColor Red
    exit 1
}
$imgSize = (Get-Item $imgFile).Length
$imgMB = [math]::Round($imgSize / 1MB)
Write-Host "Image: $imgFile ($imgMB MB)"

# Find USB
$usbDisks = @(Get-Disk | Where-Object { $_.BusType -eq "USB" })
if ($usbDisks.Count -eq 0) {
    Write-Host "ERROR: No USB drives found" -ForegroundColor Red
    exit 1
}

$targetDisk = $usbDisks[0]
$diskNum = $targetDisk.Number
$diskName = $targetDisk.FriendlyName.Trim()
$diskGB = [math]::Round($targetDisk.Size / 1GB)
Write-Host "Target: Disk $diskNum - $diskName ($diskGB GB)"

# Clean disk
Write-Host "Cleaning disk..."
"select disk $diskNum`nclean" | Out-File "$env:TEMP\frost-dp.txt" -Encoding ASCII
diskpart /s "$env:TEMP\frost-dp.txt" 2>&1 | Out-Null
Start-Sleep 2

# Write image
Write-Host "Writing image to USB..."
$diskPath = "\\.\PHYSICALDRIVE$diskNum"
$bufferSize = 4 * 1024 * 1024

$source = [System.IO.File]::OpenRead($imgFile)
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

    $now = Get-Date
    if (($now - $lastReport).TotalSeconds -ge 5) {
        $pct = [math]::Round($written * 100 / $totalBytes, 1)
        $elapsed = ($now - $startTime).TotalSeconds
        $speed = [math]::Round($written / 1MB / $elapsed, 1)
        Write-Host "  $([math]::Round($written/1MB)) / $imgMB MB ($pct%) - ${speed} MB/s"
        $lastReport = $now
    }
}

$dest.Flush()
$dest.Close()
$source.Close()

$totalTime = [math]::Round(((Get-Date) - $startTime).TotalSeconds)
Write-Host "Image written in $totalTime seconds" -ForegroundColor Green

# Bring disk online
Start-Sleep 2
try { Set-Disk -Number $diskNum -IsOffline $false -ErrorAction SilentlyContinue } catch { }
"select disk $diskNum`nonline disk`nattributes disk clear readonly" | Out-File "$env:TEMP\frost-dp.txt" -Encoding ASCII
diskpart /s "$env:TEMP\frost-dp.txt" 2>&1 | Out-Null
Start-Sleep 2

Write-Host "=== Deploy complete ===" -ForegroundColor Green
