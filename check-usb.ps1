$ErrorActionPreference = "SilentlyContinue"
try {
    $parts = Get-Partition -DiskNumber 1
    if ($parts) {
        Write-Host "USB has $($parts.Count) partitions:"
        foreach ($p in $parts) {
            $sizeMB = [math]::Round($p.Size / 1MB)
            Write-Host "  Part $($p.PartitionNumber): ${sizeMB} MB  Type=$($p.Type)"
        }
        Write-Host "DEPLOY COMPLETE"
    } else {
        Write-Host "NO PARTITIONS - deploy failed or not run yet"
    }
} catch {
    Write-Host "NO PARTITIONS FOUND"
}
