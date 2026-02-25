$ErrorActionPreference = "Stop"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

$imgFile = "C:\Users\thoma\Documents\frOSt\frost.img"
$diskNum = 1

Write-Host "=== frOSt Deploy (recovery mode) ==="

# Step 1: Recover disk with diskpart
Write-Host "Step 1: Recovering disk with diskpart..."
$dpScript = @"
select disk $diskNum
clean
create partition primary
format fs=fat32 quick
assign
"@
$dpScript | Out-File "$env:TEMP\frost-recover.txt" -Encoding ASCII
$dpOut = & diskpart /s "$env:TEMP\frost-recover.txt" 2>&1 | Out-String
Write-Host $dpOut
Start-Sleep 3

# Step 2: Now write the image
$diskPath = "\\.\PHYSICALDRIVE$diskNum"
$bufferSize = 4 * 1024 * 1024
$imgSize = (Get-Item $imgFile).Length
$imgMB = [math]::Round($imgSize / 1MB)

Write-Host "Step 2: Writing image ($imgMB MB) to $diskPath..."

# Remove any drive letters first
Get-Partition -DiskNumber $diskNum -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.DriveLetter) {
        try { Remove-PartitionAccessPath -DiskNumber $diskNum -PartitionNumber $_.PartitionNumber -AccessPath "$($_.DriveLetter):\" -ErrorAction SilentlyContinue } catch {}
    }
}
Start-Sleep 1

# Clean again right before write
"select disk $diskNum`nclean" | Out-File "$env:TEMP\frost-dp.txt" -Encoding ASCII
diskpart /s "$env:TEMP\frost-dp.txt" 2>&1 | Out-Null
Start-Sleep 2

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
try { Set-Disk -Number $diskNum -IsOffline $false -ErrorAction SilentlyContinue } catch {}
"select disk $diskNum`nonline disk" | Out-File "$env:TEMP\frost-dp.txt" -Encoding ASCII
diskpart /s "$env:TEMP\frost-dp.txt" 2>&1 | Out-Null

Write-Host "=== Deploy complete ===" -ForegroundColor Green

# Write status file so we can check from bash
"DEPLOY_COMPLETE $(Get-Date)" | Out-File "C:\Users\thoma\Documents\frOSt\deploy-status.txt" -Encoding ASCII
