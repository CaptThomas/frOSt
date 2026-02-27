# frOSt QEMU Test Script
# Launches QEMU with serial output to file, waits, then reads output
param([int]$WaitSeconds = 60)

$img = "C:\Users\thoma\Documents\frOSt\frost.img"
$qemu = "C:\Program Files\qemu\qemu-system-x86_64.exe"
$serial = "C:\Users\thoma\Documents\frOSt\serial-out.txt"

# Create serial output file
"" | Set-Content $serial

Write-Host "Starting QEMU..."

# Use named pipe for serial
$proc = Start-Process -FilePath $qemu -ArgumentList @(
    "-drive", "file=$img,format=raw",
    "-m", "2048",
    "-smp", "2",
    "-chardev", "file,id=serial0,path=$serial",
    "-serial", "chardev:serial0",
    "-display", "gtk",
    "-no-reboot"
) -PassThru -ErrorAction Stop

Write-Host "QEMU PID: $($proc.Id)"
Write-Host "Waiting ${WaitSeconds}s for boot..."

Start-Sleep -Seconds $WaitSeconds

if (-not $proc.HasExited) {
    Write-Host "Stopping QEMU..."
    $proc.Kill()
}

Write-Host ""
Write-Host "=== Serial Output ==="
if (Test-Path $serial) {
    $content = Get-Content $serial -Raw
    if ($content.Length -gt 0) {
        Write-Host $content
    } else {
        Write-Host "(serial log is empty)"
    }
} else {
    Write-Host "(serial log not found)"
}
