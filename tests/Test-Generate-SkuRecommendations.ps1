[CmdletBinding()]
param([switch]$KeepArtifacts)

$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('sql-sku-tests-' + [guid]::NewGuid())
$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) '04-Generate-SkuRecommendations.ps1'
$script:calls = [System.Collections.Generic.List[object]]::new()

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Get-Module {
    param([string]$Name, [switch]$ListAvailable)
    if ($Name -ne 'Az.DataMigration' -or -not $ListAvailable) { throw 'Unexpected module lookup.' }
    [pscustomobject]@{ Version=[version]'1.0.0' }
}

function Import-Module {
    param([string]$Name, [switch]$Force)
    if ($Name -ne 'Az.DataMigration' -or -not $Force) { throw 'Unexpected module import.' }
}

function Get-AzDataMigrationSkuRecommendation {
    [CmdletBinding()]
    param(
        [string]$OutputFolder, [string]$TargetPlatform, [int]$TargetPercentile, [int]$ScalingFactor,
        [switch]$Overwrite, [switch]$DisplayResult, [switch]$ElasticStrategy
    )
    $calls.Add([pscustomobject]@{
        Target=$TargetPlatform; Elastic=[bool]$ElasticStrategy
        ExplicitStrategy=$PSBoundParameters.ContainsKey('ElasticStrategy')
        Percentile=$TargetPercentile; Scaling=$ScalingFactor
        Overwrite=[bool]$Overwrite; DisplayResult=[bool]$DisplayResult
    })
    "Instance name: $((Get-Item -LiteralPath $OutputFolder).Name)"
    "SKU recommendation: Mock $TargetPlatform"
}

try {
    $performance = Join-Path $testRoot 'performance'
    foreach ($instance in @('demo-default', 'demo-named')) {
        $folder = Join-Path $performance $instance
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $folder 'sample_Counters.csv') | Out-Null
    }
    $cases = @(
        @{ name='elastic'; elastic=$true; targets=@('AzureSqlDatabase','AzureSqlManagedInstance','AzureSqlVirtualMachine','Any') }
        @{ name='baseline'; elastic=$false; targets=@('AzureSqlDatabase','AzureSqlManagedInstance','AzureSqlVirtualMachine','Any') }
        @{ name='mixed-case'; elastic=$true; targets=@('azuresqlmanagedinstance','AZURESQLVIRTUALMACHINE','azuresqldatabase') }
        @{ name='defaults'; elastic=$true; targets=$null }
    )
    foreach ($case in $cases) {
        $script:calls.Clear()
        $arguments = @{
            PerformanceFolder=$performance; OutputRoot=(Join-Path $testRoot $case.name)
            TargetPercentile=90; ScalingFactor=150; ElasticStrategy=$case.elastic
        }
        if ($null -ne $case.targets) { $arguments.TargetPlatform = $case.targets }
        $warnings = @()
        & $scriptPath @arguments -WarningVariable warnings -WarningAction SilentlyContinue
        $targets = if ($null -ne $case.targets) { $case.targets } else {
            @('AzureSqlDatabase','AzureSqlManagedInstance','AzureSqlVirtualMachine')
        }
        Assert-True ($script:calls.Count -eq 2 * $targets.Count) "$($case.name): every instance/target was invoked"
        foreach ($call in $script:calls) {
            $expected = $case.elastic -and ($call.Target -notin @('AzureSqlManagedInstance','AzureSqlVirtualMachine'))
            Assert-True ($call.Elastic -eq $expected -and $call.ExplicitStrategy) "$($case.name): explicit effective strategy for $($call.Target)"
            Assert-True ($call.Percentile -eq 90 -and $call.Scaling -eq 150 -and $call.Overwrite -and $call.DisplayResult) 'Existing sizing and output parameters are preserved'
        }
        $expectedWarnings = @($targets | Where-Object { $case.elastic -and $_ -in @('AzureSqlManagedInstance','AzureSqlVirtualMachine') }).Count
        Assert-True ($warnings.Count -eq $expectedWarnings) "$($case.name): overridden targets warn once per run"
        $run = Get-ChildItem -LiteralPath $arguments.OutputRoot -Directory | Select-Object -First 1
        $settings = Get-Content -LiteralPath (Join-Path $run.FullName 'recommendation-settings.json') -Raw | ConvertFrom-Json
        Assert-True ($settings.ElasticStrategy -eq $case.elastic) 'Settings preserve the requested strategy'
        foreach ($target in $targets) {
            $expected = $case.elastic -and ($target -notin @('AzureSqlManagedInstance','AzureSqlVirtualMachine'))
            Assert-True ($settings.ElasticStrategyByTarget.$target -eq $expected) "Settings record effective strategy for $target"
            foreach ($instance in @('demo-default', 'demo-named')) {
                $console = Join-Path $run.FullName (Join-Path $instance (Join-Path $target "$instance-$target-console.txt"))
                Assert-True (Test-Path -LiteralPath $console) 'Per-target console output is retained'
            }
        }
    }
    Write-Host "SKU strategy tests passed on PowerShell $($PSVersionTable.PSVersion)."
} finally {
    if ($KeepArtifacts) {
        Write-Host "Test artifacts retained at: $testRoot"
    } elseif (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
