Get-PnpDevice -Class Net | Where-Object { $_.Status -eq 'OK' -or $_.Status -eq 'Error' } | Select-Object FriendlyName, InstanceId, Status | Format-Table -AutoSize

Write-Host ""
Write-Host "=== WiFi adapter details ==="
Get-NetAdapter | Where-Object { $_.InterfaceDescription -like '*Wire*' -or $_.InterfaceDescription -like '*Wi*' } | Select-Object Name, InterfaceDescription, Status, DriverVersion | Format-Table -AutoSize

Write-Host ""
Write-Host "=== PCI WiFi device ==="
Get-PnpDevice | Where-Object { $_.FriendlyName -like '*Wire*' -or $_.FriendlyName -like '*Wi-Fi*' -or $_.FriendlyName -like '*Intel*Wire*' } | Select-Object FriendlyName, InstanceId | Format-Table -AutoSize
