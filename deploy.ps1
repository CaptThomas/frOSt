# =============================================================================
# frOSt USB Deploy Script (Windows PowerShell)
# =============================================================================
# Writes frost.img to a USB drive using Win32 CreateFile API for raw disk
# access with proper volume locking.
#
# Usage: Right-click > Run with PowerShell, or:
#   powershell -ExecutionPolicy Bypass -File deploy.ps1
#
# Auto-elevates to admin. Writes status to deploy-status.txt for monitoring.
# =============================================================================

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$statusFile = Join-Path $scriptDir "deploy-status.txt"

# ── Auto-elevate ──
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    "ELEVATING" | Out-File $statusFile -Encoding UTF8
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`""
    exit
}

"STARTED" | Out-File $statusFile -Encoding UTF8

# ── Configuration ──
$imgFile = Join-Path $scriptDir "frost.img"
$diskNum = 1
$bufferSize = 4 * 1024 * 1024

if (-not (Test-Path $imgFile)) {
    "FAILED: Image not found at $imgFile" | Out-File $statusFile -Encoding UTF8
    exit 1
}

# ── Verify disk exists ──
try {
    $disk = Get-Disk -Number $diskNum -ErrorAction Stop
    "DISK: $($disk.FriendlyName) Size=$([math]::Round($disk.Size/1GB))GB" | Out-File $statusFile -Encoding UTF8
} catch {
    "FAILED: Disk $diskNum not found" | Out-File $statusFile -Encoding UTF8
    exit 1
}

# ── Win32 API for raw disk access ──
Add-Type @"
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public class RawDisk {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern SafeFileHandle CreateFile(
        string lpFileName, uint dwDesiredAccess, uint dwShareMode,
        IntPtr lpSecurityAttributes, uint dwCreationDisposition,
        uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool DeviceIoControl(
        SafeFileHandle hDevice, uint dwIoControlCode,
        IntPtr lpInBuffer, uint nInBufferSize,
        IntPtr lpOutBuffer, uint nOutBufferSize,
        out uint lpBytesReturned, IntPtr lpOverlapped);

    public const uint GENERIC_WRITE = 0x40000000;
    public const uint GENERIC_READ  = 0x80000000;
    public const uint FILE_SHARE_READ  = 0x1;
    public const uint FILE_SHARE_WRITE = 0x2;
    public const uint OPEN_EXISTING = 3;
    public const uint FILE_FLAG_NO_BUFFERING   = 0x20000000;
    public const uint FILE_FLAG_WRITE_THROUGH  = 0x80000000;
    public const uint FSCTL_LOCK_VOLUME    = 0x00090018;
    public const uint FSCTL_DISMOUNT_VOLUME = 0x00090020;

    public static SafeFileHandle OpenDisk(string path) {
        return CreateFile(path,
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            IntPtr.Zero, OPEN_EXISTING,
            FILE_FLAG_NO_BUFFERING | FILE_FLAG_WRITE_THROUGH,
            IntPtr.Zero);
    }

    public static bool LockVolume(SafeFileHandle h) {
        uint br; return DeviceIoControl(h, FSCTL_LOCK_VOLUME, IntPtr.Zero, 0, IntPtr.Zero, 0, out br, IntPtr.Zero);
    }

    public static bool DismountVolume(SafeFileHandle h) {
        uint br; return DeviceIoControl(h, FSCTL_DISMOUNT_VOLUME, IntPtr.Zero, 0, IntPtr.Zero, 0, out br, IntPtr.Zero);
    }
}
"@

# ── Prepare disk (online, remove partitions) ──
"PREPARING disk..." | Out-File $statusFile -Encoding UTF8
try { Set-Disk -Number $diskNum -IsOffline $false -ErrorAction SilentlyContinue } catch {}
try { Set-Disk -Number $diskNum -IsReadOnly $false -ErrorAction SilentlyContinue } catch {}
Get-Partition -DiskNumber $diskNum -ErrorAction SilentlyContinue | ForEach-Object {
    try { Remove-Partition -DiskNumber $diskNum -PartitionNumber $_.PartitionNumber -Confirm:$false -ErrorAction SilentlyContinue } catch {}
}
Start-Sleep 1

# ── Lock and dismount volumes ──
$volumes = Get-Partition -DiskNumber $diskNum -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | ForEach-Object { $_.DriveLetter }
foreach ($vol in $volumes) {
    try {
        $vh = [RawDisk]::OpenDisk("\\.\${vol}:")
        if (-not $vh.IsInvalid) { [RawDisk]::LockVolume($vh) | Out-Null; [RawDisk]::DismountVolume($vh) | Out-Null; $vh.Close() }
    } catch {}
}

# ── Open physical drive ──
$diskPath = "\\.\PHYSICALDRIVE$diskNum"
$handle = [RawDisk]::OpenDisk($diskPath)
if ($handle.IsInvalid) {
    $e = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    "FAILED: Cannot open $diskPath (Win32 error $e)" | Out-File $statusFile -Encoding UTF8
    exit 1
}
[RawDisk]::LockVolume($handle) | Out-Null
[RawDisk]::DismountVolume($handle) | Out-Null

# ── Write image ──
$imgSize = (Get-Item $imgFile).Length
$imgMB = [math]::Round($imgSize / 1MB)
"WRITING $imgMB MB..." | Out-File $statusFile -Encoding UTF8

try {
    $source = [System.IO.File]::OpenRead($imgFile)
    $dest = New-Object System.IO.FileStream($handle, [System.IO.FileAccess]::Write)
    $buffer = New-Object byte[] $bufferSize
    $written = [long]0
    $startTime = Get-Date

    while (($bytesRead = $source.Read($buffer, 0, $bufferSize)) -gt 0) {
        if ($bytesRead % 512 -ne 0) {
            $aligned = [math]::Ceiling($bytesRead / 512) * 512
            for ($i = $bytesRead; $i -lt $aligned; $i++) { $buffer[$i] = 0 }
            $bytesRead = $aligned
        }
        $dest.Write($buffer, 0, $bytesRead)
        $written += $bytesRead
        $pct = [math]::Round($written * 100 / $imgSize, 1)
        $elapsed = ((Get-Date) - $startTime).TotalSeconds
        $speed = if ($elapsed -gt 0) { [math]::Round($written / 1MB / $elapsed, 1) } else { 0 }
        "PROGRESS $([math]::Round($written/1MB))/$imgMB MB ($pct%) ${speed} MB/s" | Out-File $statusFile -Encoding UTF8
    }

    $dest.Flush(); $source.Close(); $dest.Close(); $handle.Close()
    $totalTime = [math]::Round(((Get-Date) - $startTime).TotalSeconds)
    "WRITTEN in $totalTime seconds" | Out-File $statusFile -Encoding UTF8
} catch {
    if ($source) { try { $source.Close() } catch {} }
    if ($dest) { try { $dest.Close() } catch {} }
    if ($handle -and -not $handle.IsInvalid) { try { $handle.Close() } catch {} }
    "FAILED: $_" | Out-File $statusFile -Encoding UTF8
    exit 1
}

# ── Bring disk back online ──
Start-Sleep 2
$dp = "select disk $diskNum`nonline disk`nattributes disk clear readonly"
$dp | Out-File "$env:TEMP\frost-dp.txt" -Encoding ASCII
diskpart /s "$env:TEMP\frost-dp.txt" 2>&1 | Out-Null
Start-Sleep 2

try {
    $parts = Get-Partition -DiskNumber $diskNum -ErrorAction Stop
    "COMPLETE: $($parts.Count) partitions" | Out-File $statusFile -Encoding UTF8
} catch {
    "COMPLETE: Image written" | Out-File $statusFile -Encoding UTF8
}
