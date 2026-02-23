# Fix GPT on USB after image write, then bring online
param([int]$DiskNumber = 1)

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`" -DiskNumber $DiskNumber" -Wait
    exit
}

Write-Host "Fixing GPT on disk $DiskNumber..." -ForegroundColor Cyan

# Mount into WSL
wsl --unmount "\\.\PHYSICALDRIVE$DiskNumber" 2>$null
wsl --mount "\\.\PHYSICALDRIVE$DiskNumber" --bare 2>&1
Start-Sleep 2

# Find device and fix GPT
$targetSize = (Get-Disk -Number $DiskNumber).Size
wsl -d Ubuntu -u root -- bash -c @"
for dev in /dev/sd?; do
    [ -b `"`$dev`" ] || continue
    sz=`$(blockdev --getsize64 `"`$dev`" 2>/dev/null || echo 0)
    diff=`$(( sz - $targetSize ))
    [ `$diff -lt 0 ] && diff=`$(( -diff ))
    if [ `$diff -lt 2147483648 ]; then
        echo Found device: `$dev
        echo Fixing GPT backup table...
        sgdisk -e `$dev 2>/dev/null && echo GPT fixed || {
            echo sgdisk failed, trying parted...
            parted -s `$dev print fix fix 2>/dev/null
        }
        echo Verifying partitions...
        parted -s `$dev print 2>/dev/null
        echo Expanding partition 3...
        parted -s `$dev resizepart 3 100% 2>/dev/null || echo Partition expand skipped
        PART3=`${dev}3
        if [ -b `$PART3 ]; then
            e2fsck -f -y `$PART3 2>/dev/null || true
            resize2fs `$PART3 2>/dev/null || echo resize2fs skipped
        fi
        parted -s `$dev print 2>/dev/null
        sync
        exit 0
    fi
done
echo ERROR: Device not found
"@ 2>&1 | ForEach-Object { Write-Host $_ }

# Unmount
Start-Sleep 1
wsl --unmount "\\.\PHYSICALDRIVE$DiskNumber" 2>$null
Start-Sleep 2

# Bring online
Set-Disk -Number $DiskNumber -IsOffline $false -ErrorAction SilentlyContinue
Start-Sleep 2

# Show result
try {
    $parts = Get-Partition -DiskNumber $DiskNumber
    $parts | Format-Table PartitionNumber, @{N='SizeMB';E={[math]::Round($_.Size/1MB)}}, Type, DriveLetter -AutoSize
    Write-Host "SUCCESS: USB drive is ready" -ForegroundColor Green
} catch {
    Write-Host "Partitions not visible in Windows (expected for Linux partitions)" -ForegroundColor Yellow
    Write-Host "The drive should still boot - test with QEMU" -ForegroundColor Yellow
}

Start-Sleep 5
