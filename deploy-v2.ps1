$ErrorActionPreference = "Stop"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

$imgFile = "C:\Users\thoma\Documents\frOSt\frost.img"
$diskNum = 1
$diskPath = "\\.\PHYSICALDRIVE$diskNum"
$bufferSize = 4 * 1024 * 1024
$imgSize = (Get-Item $imgFile).Length
$imgMB = [math]::Round($imgSize / 1MB)

Write-Host "=== frOSt Deploy (v2) ==="
Write-Host "Image: $imgMB MB"

# Skip clean, directly write to raw disk
Write-Host "Writing image directly to $diskPath..."

try {
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
} catch {
    if ($source) { try { $source.Close() } catch {} }
    if ($dest) { try { $dest.Close() } catch {} }
    Write-Host "FAILED: $_" -ForegroundColor Red
    exit 1
}

# Bring disk online / rescan
Start-Sleep 2
try { Set-Disk -Number $diskNum -IsOffline $false -ErrorAction SilentlyContinue } catch {}
"select disk $diskNum`nonline disk`nattributes disk clear readonly" | Out-File "$env:TEMP\frost-dp.txt" -Encoding ASCII
diskpart /s "$env:TEMP\frost-dp.txt" 2>&1 | Out-Null
Start-Sleep 2

# Verify partitions
try {
    $parts = Get-Partition -DiskNumber $diskNum -ErrorAction Stop
    Write-Host "Success: $($parts.Count) partitions found"
} catch {
    Write-Host "Warning: Windows can't read partitions (GPT/EFI), but image was written"
}

Write-Host "=== Deploy complete ==="
