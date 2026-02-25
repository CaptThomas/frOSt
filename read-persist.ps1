# Read persist partition from USB and save to file for WSL to mount
param(
    [string]$OutputPath = "C:\Users\thoma\Documents\frOSt\persist-dump.img"
)

$ErrorActionPreference = "Stop"
$diskPath = "\\.\PHYSICALDRIVE1"
$offset = 3204448256  # Partition 3 offset
$size = 1089470464    # Partition 3 size
$bufferSize = 4 * 1024 * 1024  # 4MB blocks

Write-Host "Reading persist partition from USB..."
Write-Host "  Offset: $offset"
Write-Host "  Size: $([math]::Round($size / 1MB)) MB"

$source = [System.IO.FileStream]::new(
    $diskPath,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::ReadWrite,
    $bufferSize
)

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
    $pct = [math]::Round($read * 100 / $size)
    Write-Host "`r  $([math]::Round($read/1MB)) / $([math]::Round($size/1MB)) MB ($pct%)" -NoNewline
}

$source.Close()
$dest.Close()

Write-Host ""
Write-Host "Persist partition saved to: $OutputPath"
Write-Host "Size: $([math]::Round((Get-Item $OutputPath).Length / 1MB)) MB"
