[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PerformanceFolder,
    [string]$OutputRoot = (Join-Path $PSScriptRoot 'results'),
    [ValidateSet('AzureSqlDatabase','AzureSqlManagedInstance','AzureSqlVirtualMachine','Any')]
    [string[]]$TargetPlatform = @('AzureSqlDatabase','AzureSqlManagedInstance','Any'),
    [ValidateRange(50,200)][int]$TargetPercentile = 95,
    [ValidateRange(100,300)][int]$ScalingFactor = 125,
    [switch]$ElasticStrategy
)
. (Join-Path $PSScriptRoot 'Common.ps1')
Assert-DataMigrationModule
if (-not (Test-Path $PerformanceFolder)) { throw "Performance folder not found: $PerformanceFolder" }
$PerformanceFolder = (Resolve-Path $PerformanceFolder).Path
$runFolder = New-TimestampedFolder $OutputRoot 'recommendations'
$instanceFolders = @(Get-ChildItem $PerformanceFolder -Directory | Where-Object {
    @(Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*console*' -and $_.Name -notlike '*error*' }).Count -gt 0
})
if ($instanceFolders.Count -eq 0) {
    $instanceFolders = @((Get-Item $PerformanceFolder))
}

foreach ($instanceFolder in $instanceFolders) {
    $sourceName = ($instanceFolder.Name -replace '[^A-Za-z0-9._-]', '_')
    foreach ($target in $TargetPlatform) {
        Write-Host "Generating $target recommendations for $sourceName..."
        $before = @(Get-ChildItem $instanceFolder.FullName -Recurse -File |
            Select-Object FullName,LastWriteTimeUtc,Length)
        $params = @{
            OutputFolder=$instanceFolder.FullName
            TargetPlatform=$target
            TargetPercentile=$TargetPercentile
            ScalingFactor=$ScalingFactor
            Overwrite=$true
            DisplayResult=$true
        }
        if ($ElasticStrategy) { $params.ElasticStrategy = $true }
        $targetFolder = Join-Path $runFolder (Join-Path $sourceName $target)
        New-Item -ItemType Directory -Path $targetFolder -Force | Out-Null
        $consolePath = Join-Path $targetFolder "$sourceName-$target-console.txt"
        Get-AzDataMigrationSkuRecommendation @params 2>&1 |
            Tee-Object -FilePath $consolePath | Out-Host

        $after = @(Get-ChildItem $instanceFolder.FullName -Recurse -File)
        foreach ($file in $after) {
            $old = $before | Where-Object FullName -eq $file.FullName | Select-Object -First 1
            if (-not $old -or $file.LastWriteTimeUtc -gt $old.LastWriteTimeUtc -or $file.Length -ne $old.Length) {
                Copy-Item $file.FullName (Join-Path $targetFolder "$sourceName-$($file.Name)") -Force
            }
        }
    }
}
@{
    PerformanceFolder=$PerformanceFolder; Targets=$TargetPlatform; TargetPercentile=$TargetPercentile
    ScalingFactor=$ScalingFactor; ElasticStrategy=[bool]$ElasticStrategy; GeneratedUtc=(Get-Date).ToUniversalTime().ToString('o')
} | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $runFolder 'recommendation-settings.json')
Write-Host "Recommendations completed. Output: $runFolder"
