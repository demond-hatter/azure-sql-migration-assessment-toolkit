[CmdletBinding()]
param(
    [string]$InventoryPath = (Join-Path $PSScriptRoot 'servers.csv'),
    [string]$OutputRoot = (Join-Path $PSScriptRoot 'results'),
    [ValidateRange(1,20)][int]$BatchSize = 4
)
. (Join-Path $PSScriptRoot 'Common.ps1')
Assert-DataMigrationModule
$inventory = Import-AssessmentInventory $InventoryPath
$connections = Get-AssessmentConnectionStrings $inventory
$runFolder = New-TimestampedFolder $OutputRoot 'compatibility'
$failedInstances = @()

function Get-SafeAssessmentName {
    param([Parameter(Mandatory)]$Connection)
    $name = $Connection.ServerName
    if ($Connection.InstanceName) {
        $name += "_$($Connection.InstanceName)"
    }
    elseif ($Connection.Port) {
        $name += "_port$($Connection.Port)"
    }
    return ($name -replace '[^A-Za-z0-9._-]', '_').Trim('_')
}

for ($start = 0; $start -lt $connections.Count; $start += $BatchSize) {
    $end = [math]::Min($start + $BatchSize - 1, $connections.Count - 1)
    $batch = @($connections[$start..$end])
    $batchNumber = [int]($start / $BatchSize) + 1
    $batchFolder = Join-Path $runFolder ("batch-{0:D2}" -f $batchNumber)
    New-Item -ItemType Directory -Path $batchFolder -Force | Out-Null
    $batch | Select-Object Name,ServerName,InstanceName,Port,DataSource |
        Export-Csv (Join-Path $batchFolder 'servers.csv') -NoTypeInformation
    Write-Host "Assessing batch $($batchNumber): $($batch.Name -join ', ')"

    # Run each source separately so every report can be attributed and named
    # with its source server and instance rather than producing one batch file.
    foreach ($connection in $batch) {
        $sourceName = Get-SafeAssessmentName $connection
        $instanceFolder = Join-Path $batchFolder $sourceName
        New-Item -ItemType Directory -Path $instanceFolder -Force | Out-Null
        $connection | Select-Object Name,ServerName,InstanceName,Port,DataSource |
            Export-Csv (Join-Path $instanceFolder "$sourceName-source.csv") -NoTypeInformation
        Write-Host "  Assessing $($connection.DataSource)..."

        try {
            $consolePath = Join-Path $instanceFolder "$sourceName-assessment-console.txt"
            $assessmentOutput = @(
                Get-AzDataMigrationAssessment `
                    -ConnectionString ([string[]]@($connection.ConnectionString)) `
                    -OutputFolder $instanceFolder `
                    -Overwrite 2>&1
            )
            $assessmentOutput | Tee-Object -FilePath $consolePath | Out-Host

            # The Az.DataMigration wrapper can return True even when its downloaded
            # native executable reports a failure, so inspect the actual output.
            $outputText = $assessmentOutput | Out-String
            if ($outputText -match '(?i)failed to parse|assessment failed|unhandled exception|you must install or update \.net|error occurred') {
                throw "SqlAssessment.exe reported a failure. Review $consolePath."
            }

            Get-ChildItem $instanceFolder -File |
                Where-Object {
                    $_.Name -notlike "$sourceName-*" -and
                    $_.Name -ne 'servers.csv'
                } |
                ForEach-Object {
                    Rename-Item $_.FullName -NewName "$sourceName-$($_.Name)"
                }
            Write-Host "  $sourceName completed successfully." -ForegroundColor Green
        }
        catch {
            $_ | Out-String | Set-Content (Join-Path $instanceFolder "$sourceName-assessment-error.txt")
            $failedInstances += $connection.DataSource
            Write-Warning "$($connection.DataSource) failed. Review its assessment-error file."
        }
    }
}
if ($failedInstances.Count -gt 0) {
    throw "Compatibility assessment failed for: $($failedInstances -join ', '). Output: $runFolder"
}
Write-Host "Compatibility assessment completed successfully. Output: $runFolder"
