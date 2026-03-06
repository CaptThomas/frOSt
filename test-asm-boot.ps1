# Test QEMU boot and capture serial output
$ErrorActionPreference = "SilentlyContinue"
Get-Process qemu-system-x86_64 | Stop-Process -Force
Start-Sleep 2

Remove-Item "C:\Users\thoma\Documents\frOSt\qemu-asm-test3.log" -Force

$qemuArgs = @(
    "-m", "2048",
    "-smp", "2",
    "-kernel", "C:\Users\thoma\Documents\frOSt\vmlinuz-test",
    "-initrd", "C:\Users\thoma\Documents\frOSt\initramfs-test.img",
    "-append", "root=LABEL=FROST_ROOT ro console=ttyS0,115200 loglevel=4",
    "-drive", "file=C:\Users\thoma\Documents\frOSt\frost.img,format=raw,if=virtio",
    "-serial", "file:C:\Users\thoma\Documents\frOSt\qemu-asm-test3.log",
    "-display", "none",
    "-no-reboot"
)

$p = Start-Process -FilePath "C:\Program Files\qemu\qemu-system-x86_64.exe" -ArgumentList $qemuArgs -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 50
Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
Start-Sleep 2

$logFile = "C:\Users\thoma\Documents\frOSt\qemu-asm-test3.log"
if (Test-Path $logFile) {
    $size = (Get-Item $logFile).Length
    Write-Host "Log file size: $size bytes"
    # Read as bytes and strip ANSI
    $raw = [System.IO.File]::ReadAllText($logFile)
    $clean = $raw -replace [char]0x1B + '\[[0-9;]*[a-zA-Z]', ''
    $lines = $clean -split "`n"
    Write-Host "Total lines: $($lines.Count)"
    Write-Host "=== LAST 100 LINES ==="
    $lines | Select-Object -Last 100 | ForEach-Object { Write-Host $_ }
} else {
    Write-Host "NO LOG FILE FOUND"
}
