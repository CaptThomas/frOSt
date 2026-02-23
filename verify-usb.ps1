# Verify USB partitions via WSL - output to file
param([int]$DiskNumber = 1)

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`" -DiskNumber $DiskNumber" -Wait
    exit
}

$outFile = "C:\Users\thoma\Documents\frOSt\usb-verify.log"
"Verifying USB drive (disk $DiskNumber)..." | Out-File $outFile

# Take offline for WSL access
Set-Disk -Number $DiskNumber -IsOffline $true -ErrorAction SilentlyContinue 2>&1 | Out-File $outFile -Append
Start-Sleep 1

wsl --unmount "\\.\PHYSICALDRIVE$DiskNumber" 2>&1 | Out-File $outFile -Append
$mountOut = wsl --mount "\\.\PHYSICALDRIVE$DiskNumber" --bare 2>&1
$mountOut | Out-File $outFile -Append
Start-Sleep 3

$targetSize = (Get-Disk -Number $DiskNumber).Size
"Target size: $targetSize" | Out-File $outFile -Append

$output = wsl -d Ubuntu -u root -- bash -c @"
echo '=== Block devices ==='
lsblk 2>/dev/null
echo ''
for dev in /dev/sd?; do
    [ -b `"`$dev`" ] || continue
    sz=`$(blockdev --getsize64 `"`$dev`" 2>/dev/null || echo 0)
    echo "Device `$dev size: `$sz"
    diff=`$(( sz - $targetSize ))
    [ `$diff -lt 0 ] && diff=`$(( -diff ))
    if [ `$diff -lt 2147483648 ]; then
        echo "=== Found USB: `$dev (`$(( sz / 1073741824 )) GB) ==="
        echo '=== fdisk ==='
        fdisk -l `$dev 2>/dev/null
        echo '=== parted ==='
        parted -s `$dev print 2>/dev/null || echo 'parted failed'
        echo '=== sgdisk ==='
        sgdisk -p `$dev 2>/dev/null || echo 'sgdisk failed'
        echo '=== Mount test ==='
        mkdir -p /tmp/efi_chk
        mount `${dev}1 /tmp/efi_chk 2>&1 && {
            echo 'EFI OK:' && ls /tmp/efi_chk/ && ls /tmp/efi_chk/EFI/BOOT/ 2>/dev/null && ls /tmp/efi_chk/boot/ 2>/dev/null
            umount /tmp/efi_chk
        } || echo 'EFI mount failed'
        mkdir -p /tmp/root_chk
        mount `${dev}2 /tmp/root_chk 2>&1 && {
            echo 'Root OK:' && ls -la /tmp/root_chk/
            umount /tmp/root_chk
        } || echo 'Root mount failed'
        exit 0
    fi
done
echo 'USB device not found'
"@ 2>&1
$output | Out-File $outFile -Append

wsl --unmount "\\.\PHYSICALDRIVE$DiskNumber" 2>$null | Out-File $outFile -Append
Start-Sleep 1
Set-Disk -Number $DiskNumber -IsOffline $false -ErrorAction SilentlyContinue 2>&1 | Out-File $outFile -Append

"DONE" | Out-File $outFile -Append
