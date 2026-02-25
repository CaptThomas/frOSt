$ErrorActionPreference = "Stop"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

Write-Host "=== Attempting to recover USB disk ==="

# Method 1: Diskpart create partition
$script = @"
select disk 1
clean
create partition primary
format fs=fat32 quick
assign
"@
$script | Out-File "$env:TEMP\frost-recover.txt" -Encoding ASCII
$out = & diskpart /s "$env:TEMP\frost-recover.txt" 2>&1 | Out-String
Write-Host $out

Start-Sleep -Seconds 3

$disk = Get-Disk -Number 1 -ErrorAction SilentlyContinue
Write-Host "Disk 1: Size=$($disk.Size), Status=$($disk.OperationalStatus), Name=$($disk.FriendlyName)"

if ($disk.Size -gt 0) {
    Write-Host "USB recovered! Now deploying..."
    & powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\thoma\Documents\frOSt\deploy-usb.ps1" -DiskNumber 1 -Yes
} else {
    Write-Host "USB still not available. Physical replug required."
}
