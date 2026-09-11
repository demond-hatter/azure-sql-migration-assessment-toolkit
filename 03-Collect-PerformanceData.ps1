[CmdletBinding()]
param(
    [string]$InventoryPath = (Join-Path $PSScriptRoot 'servers.csv'),
    [string]$OutputRoot = (Join-Path $PSScriptRoot 'results'),
    [ValidateRange(1,744)][int]$DurationHours = 168,
    [ValidateRange(15,300)][int]$PerformanceQueryIntervalSeconds = 30,
    [ValidateRange(300,86400)][int]$StaticQueryIntervalSeconds = 3600,
    [ValidateRange(2,200)][int]$NumberOfIterations = 20
)
. (Join-Path $PSScriptRoot 'Common.ps1')
Assert-DataMigrationModule
$inventory = Import-AssessmentInventory $InventoryPath
$connections = Get-AssessmentConnectionStrings $inventory
$runFolder = New-TimestampedFolder $OutputRoot 'performance'
$connections |
    Select-Object Name,ServerName,InstanceName,Port,DataSource |
    Export-Csv (Join-Path $runFolder 'servers.csv') -NoTypeInformation
$durationSeconds = [int64]$DurationHours * 3600
$assessmentExe = Get-SqlAssessmentExecutable
$collectors = @()

Write-Host "Collecting from $($connections.Count) SQL instances for $DurationHours hour(s)."
Write-Host 'Keep this PowerShell session and the assessment machine running for the full collection window.'

try {
    foreach ($connection in $connections) {
        $sourceName = Get-SafeSourceName $connection
        $instanceFolder = Join-Path $runFolder $sourceName
        New-Item -ItemType Directory -Path $instanceFolder -Force | Out-Null
        $configPath = Join-Path $instanceFolder "$sourceName-collector-config.json"
        $stdoutPath = Join-Path $instanceFolder "$sourceName-collection-console.txt"
        $stderrPath = Join-Path $instanceFolder "$sourceName-collection-error.txt"

        [ordered]@{
            action = 'PerfDataCollection'
            sqlConnectionStrings = @($connection.ConnectionString.PSObject.BaseObject.ToString())
            outputfolder = $instanceFolder
            perfQueryIntervalInSec = [string]$PerformanceQueryIntervalSeconds
            staticQueryIntervalInSec = [string]$StaticQueryIntervalSeconds
            numberOfIterations = [string]$NumberOfIterations
        } | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding UTF8

        $process = Start-Process `
            -FilePath $assessmentExe `
            -ArgumentList "--configFile `"$configPath`"" `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -PassThru `
            -NoNewWindow

        $collectors += [pscustomobject]@{
            Name = $sourceName
            DataSource = $connection.DataSource
            Process = $process
            ConfigPath = $configPath
            StandardOutput = $stdoutPath
            StandardError = $stderrPath
        }
        Write-Host "Started collector for $($connection.DataSource) as process $($process.Id)."
    }

    $deadline = (Get-Date).AddSeconds($durationSeconds)
    while ((Get-Date) -lt $deadline) {
        $unexpected = @($collectors | Where-Object { $_.Process.HasExited })
        if ($unexpected.Count -gt 0) {
            $names = $unexpected | ForEach-Object { "$($_.DataSource) (exit $($_.Process.ExitCode))" }
            throw "Collector process ended before the requested duration: $($names -join ', '). Review its collection error and console files."
        }
        $remainingMinutes = [math]::Ceiling(($deadline - (Get-Date)).TotalMinutes)
        Write-Host "Collection running. Approximately $remainingMinutes minute(s) remaining."
        $sleepSeconds = [math]::Min(60, [math]::Max(1, [int]($deadline - (Get-Date)).TotalSeconds))
        Start-Sleep -Seconds $sleepSeconds
    }
}
finally {
    foreach ($collector in $collectors) {
        if (-not $collector.Process.HasExited) {
            Stop-Process -Id $collector.Process.Id -Force
            $collector.Process.WaitForExit()
        }
        Remove-Item $collector.ConfigPath -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Performance collection completed. Output: $runFolder"
