# Bring USB disk online and verify partitions
Set-Disk -Number 1 -IsOffline $false
Start-Sleep 2
$parts = Get-Partition -DiskNumber 1
$parts | Format-Table PartitionNumber, @{N='SizeMB';E={[math]::Round($_.Size/1MB)}}, Type, DriveLetter -AutoSize
Write-Host "Done" -ForegroundColor Green
Start-Sleep 3
