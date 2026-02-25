$ErrorActionPreference = "Stop"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

$diskPath = "\\.\PHYSICALDRIVE1"
$offset = 3204448256
$size = 1089470464
$bufferSize = 4 * 1024 * 1024
$OutputPath = "C:\Users\thoma\Documents\frOSt\persist-dump.img"

Write-Host "Reading persist partition..."
$source = [System.IO.FileStream]::new($diskPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite, $bufferSize)
$dest = [System.IO.File]::Create($OutputPath)
$source.Seek($offset, [System.IO.SeekOrigin]::Begin) | Out-Null

$buffer = New-Object byte[] $bufferSize
$remaining = $size
$read = [long]0
while ($remaining -gt 0) {
    $toRead = [math]::Min($bufferSize, $remaining)
    $bytesRead = $source.Read($buffer, 0, $toRead)
    if ($bytesRead -eq 0) { break }
    $dest.Write($buffer, 0, $bytesRead)
    $remaining -= $bytesRead
    $read += $bytesRead
    if ($read % (32 * 1024 * 1024) -lt $bufferSize) {
        Write-Host "  $([math]::Round($read/1MB)) / $([math]::Round($size/1MB)) MB"
    }
}
$source.Close()
$dest.Close()
Write-Host "Persist partition saved: $OutputPath ($([math]::Round((Get-Item $OutputPath).Length / 1MB)) MB)"
