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
$runFolder = New-TimestampedFolder $OutputRoot 'compatibility-parallel'
$assessmentExe = Get-SqlAssessmentExecutable
$failedInstances = @()

for ($start = 0; $start -lt $connections.Count; $start += $BatchSize) {
    $end = [math]::Min($start + $BatchSize - 1, $connections.Count - 1)
    $batch = @($connections[$start..$end])
    $batchNumber = [int]($start / $BatchSize) + 1
    $batchFolder = Join-Path $runFolder ("batch-{0:D2}" -f $batchNumber)
    New-Item -ItemType Directory -Path $batchFolder -Force | Out-Null
    $batch | Select-Object Name,ServerName,InstanceName,Port,DataSource |
        Export-Csv (Join-Path $batchFolder 'servers.csv') -NoTypeInformation
    Write-Host "Starting batch $($batchNumber): $($batch.Name -join ', ')"

    $processes = @()
    foreach ($connection in $batch) {
        $sourceName = Get-SafeSourceName $connection
        $instanceFolder = Join-Path $batchFolder $sourceName
        New-Item -ItemType Directory -Path $instanceFolder -Force | Out-Null
        $connection | Select-Object Name,ServerName,InstanceName,Port,DataSource |
            Export-Csv (Join-Path $instanceFolder "$sourceName-source.csv") -NoTypeInformation

        $configPath = Join-Path $instanceFolder "$sourceName-assessment-config.json"
        $stdoutPath = Join-Path $instanceFolder "$sourceName-assessment-console.txt"
        $stderrPath = Join-Path $instanceFolder "$sourceName-assessment-error.txt"
        [ordered]@{
            action = 'Assess'
            sqlConnectionStrings = @($connection.ConnectionString.PSObject.BaseObject.ToString())
            outputFolder = $instanceFolder
            overwrite = $true
        } | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding UTF8

        try {
            $process = Start-Process `
                -FilePath $assessmentExe `
                -ArgumentList "--configFile `"$configPath`"" `
                -RedirectStandardOutput $stdoutPath `
                -RedirectStandardError $stderrPath `
                -PassThru `
                -NoNewWindow
            $processes += [pscustomobject]@{
                SourceName = $sourceName
                DataSource = $connection.DataSource
                Process = $process
                InstanceFolder = $instanceFolder
                ConfigPath = $configPath
                StandardOutput = $stdoutPath
                StandardError = $stderrPath
            }
            Write-Host "  Started $($connection.DataSource) as process $($process.Id)."
        }
        catch {
            $_ | Out-String | Set-Content $stderrPath
            Remove-Item $configPath -Force -ErrorAction SilentlyContinue
            $failedInstances += $connection.DataSource
            Write-Warning "Unable to start assessment for $($connection.DataSource)."
        }
    }

    if ($processes.Count -gt 0) {
        Write-Host "Waiting for $($processes.Count) assessment process(es) in batch $($batchNumber)..."
        # Wait on the original Process objects. Querying only by ID can cause
        # Windows PowerShell to lose the native exit-code state.
        $processes | ForEach-Object {
            $_.Process.PSObject.BaseObject.WaitForExit()
        }
    }

    foreach ($entry in $processes) {
        # Unwrap the Process object before reading ExitCode. Windows PowerShell
        # can expose a blank value through a PSCustomObject property.
        $completedProcess = $entry.Process.PSObject.BaseObject
        $completedProcess.WaitForExit()
        $completedProcess.Refresh()
        $exitCode = $completedProcess.ExitCode
        $stdout = if (Test-Path $entry.StandardOutput) {
            Get-Content $entry.StandardOutput -Raw -ErrorAction SilentlyContinue
        } else { '' }
        $stderr = if (Test-Path $entry.StandardError) {
            Get-Content $entry.StandardError -Raw -ErrorAction SilentlyContinue
        } else { '' }
        $combined = "$stdout`r`n$stderr"
        $reportExists = [bool](Get-ChildItem $entry.InstanceFolder -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(?i)assessment.*\.json$|SqlAssessmentReport.*\.json$' } |
            Select-Object -First 1)
        $failureText = $combined -match '(?i)failed to parse|assessment failed|unhandled exception|you must install or update \.net|error occurred'
        $nonZeroExit = $null -ne $exitCode -and $exitCode -ne 0

        if ($nonZeroExit -or $failureText -or -not $reportExists) {
            $failedInstances += $entry.DataSource
            $exitDescription = if ($null -eq $exitCode) { 'not reported' } else { [string]$exitCode }
            Write-Warning "$($entry.DataSource) failed. Exit code: $exitDescription; assessment report found: $reportExists."
        }
        else {
            Get-ChildItem $entry.InstanceFolder -File |
                Where-Object {
                    $_.Name -notlike "$($entry.SourceName)-*" -and
                    $_.Name -ne 'servers.csv'
                } |
                ForEach-Object {
                    Rename-Item $_.FullName -NewName "$($entry.SourceName)-$($_.Name)"
                }
            Write-Host "  $($entry.DataSource) completed successfully." -ForegroundColor Green
        }
        Remove-Item $entry.ConfigPath -Force -ErrorAction SilentlyContinue
    }

    Write-Host "Batch $($batchNumber) finished. Proceeding to the next batch." -ForegroundColor Cyan
}

if ($failedInstances.Count -gt 0) {
    throw "Compatibility assessment failed for: $($failedInstances -join ', '). Output: $runFolder"
}
Write-Host "All parallel compatibility assessment batches completed successfully. Output: $runFolder"
