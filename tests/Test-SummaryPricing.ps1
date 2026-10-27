[CmdletBinding()]
param([switch]$KeepArtifacts)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'SummaryPricing.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('sql-pricing-tests-' + [guid]::NewGuid())
$script:fixtureMeters = [System.Collections.Generic.List[object]]::new()
$script:requests = [System.Collections.Generic.List[string]]::new()

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-Amount {
    param($Result, [double]$Expected, [string]$Message)
    Assert-True (-not $Result.error -and [Math]::Abs($Result.amount - $Expected) -lt .00001) "$Message (amount=$($Result.amount), error=$($Result.error))"
}

function Add-Meter {
    param(
        [string]$Product, [string]$Sku, [string]$Meter, [double]$Price,
        [string]$Unit='1 Hour', [string]$Type='Consumption', [string]$Term='',
        [string]$Region='eastus', [string]$ArmSku='', [array]$Savings=@()
    )
    $script:fixtureMeters.Add([pscustomobject]@{
        currencyCode='USD'; serviceName='Test'; armRegionName=$Region; location='US East'
        productName=$Product; skuName=$Sku; meterName=$Meter; armSkuName=$ArmSku
        type=$Type; reservationTerm=$Term; unitOfMeasure=$Unit; retailPrice=$Price
        tierMinimumUnits=0; effectiveStartDate='2026-01-01T00:00:00Z'
        meterId=[guid]::NewGuid().ToString(); savingsPlan=$Savings
    })
}

$requestLog = $script:requests
$meters = $script:fixtureMeters
$requestState = @{ mode='items' }
$mockRequest = {
    [CmdletBinding()]
    param([string]$Uri, [int]$TimeoutSec)
    $requestLog.Add($Uri)
    switch ($requestState.mode) {
        'failure' { throw 'Synthetic pricing API outage' }
        'missingItems' { return [pscustomobject]@{ unexpected='response' } }
        'invalidPage' { return [pscustomobject]@{ Items=@(); NextPageLink='https://example.invalid/api/retail/prices' } }
    }
    return [pscustomobject]@{ Items=@($meters.ToArray()); NextPageLink=$null }
}.GetNewClosure()
Set-Item -Path Function:Invoke-RestMethod -Value $mockRequest

try {
    $cases = @(
        [pscustomobject]@{ Target='AzureSqlDatabase'; Recommendation='Azure SQL Database: Compute: Gen5 - GeneralPurpose - 4 cores Storage: 100 GB' }
        [pscustomobject]@{ Target='AzureSqlManagedInstance'; Recommendation='Azure SQL Managed Instance: Compute: Gen5 - NextGenGeneralPurpose - 8 cores Storage: 256 GB' }
        [pscustomobject]@{ Target='AzureSqlVirtualMachine'; Recommendation='SQL Server on Azure VM Standard_D8s_v5 Windows Standard Edition Storage: 2 x P30 LRS' }
        [pscustomobject]@{ Target='AzureSqlDatabase'; Recommendation='Azure SQL Database: Compute: GeneralPurpose - 2 cores Storage: 11 GB' }
    )
    foreach ($case in $cases | Where-Object Target -ne 'AzureSqlVirtualMachine' | Select-Object -First 2) {
        $spec = Get-SummaryPricingSpec $case.Target $case.Recommendation
        Assert-True (-not $spec.error -and $spec.cores -gt 0) 'Supported provisioned SQL recommendation parses'
        Add-Meter $spec.computeProduct 'vCore' 'vCore' .2 -Savings @(@{term='1 Year';retailPrice=.15})
        Add-Meter $spec.computeProduct 'vCore' 'vCore' 1200 -Type Reservation -Term '1 Year'
        Add-Meter $spec.computeProduct 'vCore' 'vCore' 2400 -Type Reservation -Term '3 Years'
        Add-Meter $spec.licenseProduct 'vCore' 'vCore' .1 -Region Global
        Add-Meter $spec.storageProduct 'General Purpose' $spec.storageMeter .12 -Unit '1 GB/Month'
    }
    Add-Meter 'Virtual Machines Dsv5 Series' 'Standard_D8s_v5' 'D8s v5' .4 -ArmSku Standard_D8s_v5
    Add-Meter 'Virtual Machines Dsv5 Series Windows' 'Standard_D8s_v5' 'D8s v5' .7 -ArmSku Standard_D8s_v5
    Add-Meter 'Virtual Machines Dsv5 Series' 'Standard_D8s_v5' 'D8s v5' 1200 -ArmSku Standard_D8s_v5 -Type Reservation -Term '1 Year'
    Add-Meter 'Virtual Machines Dsv5 Series' 'Standard_D8s_v5' 'D8s v5' 2400 -ArmSku Standard_D8s_v5 -Type Reservation -Term '3 Years'
    Add-Meter 'SQL Server Standard' '8 vCPU VM' '8 vCPU VM License' .8 -Region ''
    Add-Meter 'Premium SSD Managed Disks' 'P30 LRS' 'P30 LRS Disk' 135 -Unit '1/Month'

    $unspecified = Get-SummaryPricingSpec $cases[3].Target $cases[3].Recommendation
    Assert-True ($unspecified.needsHardware -and $unspecified.computeProduct -like '*Compute Gen5') 'Missing hardware requires explicit confirmation'
    $nextGen = Get-SummaryPricingSpec $cases[1].Target $cases[1].Recommendation
    Assert-True ($nextGen.computeProduct -eq 'SQL Managed Instance General Purpose - Compute Gen5' -and $nextGen.notes.Count -gt 0) 'Next-gen baseline mapping is explicit'
    $vm = Get-SummaryPricingSpec $cases[2].Target $cases[2].Recommendation
    Assert-True ($vm.cores -eq 8 -and $vm.os -eq 'Windows' -and $vm.edition -eq 'Standard' -and $vm.disks[0].count -eq 2 -and $vm.disks[0].redundancy -eq 'LRS') 'VM size, licensing and disk quantities parse'
    $constrained = Get-SummaryPricingSpec 'AzureSqlVirtualMachine' 'SQL Server on Azure VM Standard_E64-16ds_v5'
    Assert-True ($constrained.cores -eq 16) 'Constrained-vCPU VM size is not licensed as the full host size'
    $unsupported = Get-SummaryPricingSpec 'AzureSqlDatabase' 'Azure SQL Database serverless GeneralPurpose 4 cores'
    Assert-True ([bool]$unsupported.error) 'Unsupported recommendation is explicit'

    $offline = New-SummaryPricingSnapshot -Recommendations $cases -SkipPricing
    Assert-True ($offline.skipped -and $script:requests.Count -eq 0) 'SkipPricing performs no network calls'
    $snapshot = New-SummaryPricingSnapshot -Recommendations $cases -Regions eastus
    Assert-True ($snapshot.items.Count -gt 0 -and $snapshot.errors.Count -eq 0) 'Snapshot includes queried USD meters'
    Assert-True (@($script:requests | Where-Object { $_ -notlike 'https://prices.azure.com/api/retail/prices?*' }).Count -eq 0) 'Only the documented public endpoint is queried'
    Assert-True (@($script:requests | Where-Object { [uri]::UnescapeDataString($_) -match "armRegionName eq 'eastus'" }).Count -gt 0) 'Region filter is sent'
    Assert-True (@($script:requests | Where-Object { [uri]::UnescapeDataString($_) -match "productName eq 'SQL Server Standard'" }).Count -gt 0) 'VM SQL licensing is queried separately'
    $script:requests.Clear()
    $null = New-SummaryPricingSnapshot -Recommendations @($cases[0]) -Regions Westus3,WESTUS3
    $regionalQueries = @($script:requests | ForEach-Object { [uri]::UnescapeDataString($_) } | Where-Object { $_ -cmatch "armRegionName eq 'westus3'" })
    Assert-True ($regionalQueries.Count -gt 0) 'Mixed-case ARM regions are normalized to lowercase for the case-sensitive API'
    Assert-True (@($script:requests | Where-Object { [uri]::UnescapeDataString($_) -cmatch "armRegionName eq 'Westus3'|armRegionName eq 'WESTUS3'" }).Count -eq 0) 'Original mixed-case regions are never sent'
    Assert-True (@($regionalQueries | Where-Object { $_ -match "armRegionName eq 'westus3' or armRegionName eq 'westus3'" }).Count -eq 0) 'Normalized regions are deduplicated'
    $sqlSpec = Get-SummaryPricingSpec $cases[0].Target $cases[0].Recommendation
    foreach ($expected in @(
        @{ plan='payg'; ahb=$false; amount=888 }, @{ plan='payg'; ahb=$true; amount=596 }
        @{ plan='ri1'; ahb=$false; amount=704 }, @{ plan='ri1'; ahb=$true; amount=412 }
        @{ plan='ri3'; ahb=$false; amount=(2400 * 4 / 36 + 292 + 12) }, @{ plan='ri3'; ahb=$true; amount=(2400 * 4 / 36 + 12) }
        @{ plan='dbsp1'; ahb=$false; amount=742 }, @{ plan='dbsp1'; ahb=$true; amount=450 }
    )) {
        Assert-Amount (Get-SummaryPriceEstimate $snapshot $sqlSpec eastus -Plan $expected.plan -Ahb:$expected.ahb) $expected.amount "SQL $($expected.plan) AHB=$($expected.ahb) matches browser arithmetic"
    }
    Assert-Amount (Get-SummaryPriceEstimate $snapshot $nextGen eastus) (8 * .3 * 730 + 256 * .12) 'MI quantities match browser arithmetic'
    foreach ($expected in @(
        @{ plan='payg'; ahb=$false; amount=1365 }, @{ plan='payg'; ahb=$true; amount=781 }
        @{ plan='ri1'; ahb=$false; amount=1173 }, @{ plan='ri1'; ahb=$true; amount=589 }
        @{ plan='ri3'; ahb=$false; amount=(2400 / 36 + 219 + 584 + 270) }, @{ plan='ri3'; ahb=$true; amount=(2400 / 36 + 219 + 270) }
    )) {
        Assert-Amount (Get-SummaryPriceEstimate $snapshot $vm eastus -Plan $expected.plan -Ahb:$expected.ahb) $expected.amount "VM $($expected.plan) AHB=$($expected.ahb) preserves Windows licensing and disk charges"
    }
    foreach ($ahb in @($false, $true)) {
        Assert-True ([bool](Get-SummaryPriceEstimate $snapshot $vm eastus -Plan dbsp1 -Ahb:$ahb).error) 'VM database savings plans are unavailable with and without AHB'
    }
    Assert-True ([bool](Get-SummaryPriceEstimate $snapshot $unspecified eastus).error) 'CSV never assumes missing SQL hardware'
    Assert-True ([bool](Get-SummaryPriceEstimate $snapshot $sqlSpec missingregion).error) 'CSV never falls back to another region'
    Assert-True ([bool](Get-SummaryPriceEstimate $offline $sqlSpec eastus).error) 'Skipped pricing cannot produce estimates'
    $testSnapshot = [pscustomobject]@{
        generatedUtc=$snapshot.generatedUtc; hoursPerMonth=730; skipped=$false
        items=@($script:fixtureMeters.ToArray())
    }
    $sqlCompute = $testSnapshot.items | Where-Object { $_.productName -eq $sqlSpec.computeProduct -and $_.type -eq 'Consumption' } | Select-Object -First 1
    $duplicate = $sqlCompute | Select-Object *
    $duplicate.meterId = 'ambiguous-meter'
    $duplicate.retailPrice = 99
    $testSnapshot.items += $duplicate
    Assert-True ((Get-SummaryPriceEstimate $testSnapshot $sqlSpec eastus).error -like '*Ambiguous*') 'Ambiguous CSV prices are unavailable, not guessed'
    $testSnapshot.items = @($script:fixtureMeters.ToArray() | Where-Object productName -ne $sqlSpec.licenseProduct)
    Assert-True ([bool](Get-SummaryPriceEstimate $testSnapshot $sqlSpec eastus).error) 'Missing license prevents a non-AHB estimate'
    Assert-Amount (Get-SummaryPriceEstimate $testSnapshot $sqlSpec eastus -Ahb) 596 'AHB remains valid when the license meter is missing'
    $testSnapshot.items = @($script:fixtureMeters.ToArray() | Where-Object productName -ne $sqlSpec.storageProduct)
    $subtotal = Get-SummaryPriceEstimate $testSnapshot $sqlSpec eastus
    Assert-Amount $subtotal 876 'Missing storage produces a qualified subtotal'
    Assert-True (@($subtotal.notes | Where-Object { $_ -like 'Storage excluded:*' }).Count -gt 0) 'CSV subtotal explicitly excludes missing storage'
    $testSnapshot.items = @($script:fixtureMeters.ToArray() | Where-Object { $_.productName -ne $sqlSpec.computeProduct -or $_.type -ne 'Reservation' })
    Assert-True ([bool](Get-SummaryPriceEstimate $testSnapshot $sqlSpec eastus -Plan ri1).error) 'Missing reservation is not replaced with PAYG'
    $plans = $sqlCompute.savingsPlan
    $sqlCompute.savingsPlan = @()
    Assert-True ([bool](Get-SummaryPriceEstimate $testSnapshot $sqlSpec eastus -Plan dbsp1).error) 'Missing savings-plan rate is not replaced with PAYG'
    $sqlCompute.savingsPlan = $plans
    $requestState.mode = 'failure'
    $failed = New-SummaryPricingSnapshot -Recommendations @($cases[0]) -Regions eastus -WarningAction SilentlyContinue
    Assert-True ($failed.errors.Count -gt 0 -and $failed.items.Count -eq 0) 'API failures are recorded explicitly, not replaced with zero prices'
    foreach ($mode in @('missingItems', 'invalidPage')) {
        $requestState.mode = $mode
        $failure = $null
        try { Get-SummaryRetailPrices "serviceName eq 'SQL Database'" | Out-Null } catch { $failure = $_ }
        Assert-True ($null -ne $failure) "Malformed API response is rejected: $mode"
    }
    $requestState.mode = 'items'

    $results = Join-Path $testRoot 'results'
    $summary = Join-Path $testRoot 'summary'
    for ($i=0; $i -lt $cases.Count; $i++) {
        $folder = Join-Path $results (Join-Path "demo-$i" $cases[$i].Target)
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        $readiness = @{
            AzureSqlDatabase=@{RecommendationStatus='NotReady'}
            AzureSqlManagedInstance=@{RecommendationStatus='NotAssessed'}
            AzureSqlVirtualMachine=@{RecommendationStatus='Unknown'}
        }
        $readiness[$cases[$i].Target] = @{RecommendationStatus='Ready'}
        @{
            Servers=@(@{
                Properties=@{ServerName="demo-$i"; InstanceName=if ($i -eq 0) { 'ERP, "East"' } else { '' }}
                TargetReadinesses=$readiness
                Databases=@(@{
                    TargetReadinesses=$readiness
                    DatabaseAssessments=@(@{IssueCategory='Warning'; AppliesToMigrationTargetPlatform=$cases[$i].Target})
                })
            })
        } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $folder 'SqlAssessment.json') -Encoding UTF8
        "Instance name: demo-$i`r`nSKU recommendation: $($cases[$i].Recommendation)`r`nRecommendation reasons: Test fixture" |
            Set-Content (Join-Path $folder 'demo-console.txt')
    }
    & (Join-Path $root '05-Summarize-Results.ps1') -ResultsRoot $results -SummaryFolder $summary -PricingRegion eastus
    $htmlPath = Join-Path $summary 'assessment-summary.html'
    $html = Get-Content -LiteralPath $htmlPath -Raw -Encoding UTF8
    $json = [regex]::Match($html, "(?s)<script type='application/json' id='pricing-data'>(.*?)</script>").Groups[1].Value | ConvertFrom-Json
    Assert-True ($json.currency -eq 'USD' -and $json.items.Count -gt 0 -and -not $json.skipped) 'Snapshot is embedded in the generated HTML'
    Assert-True ($html -notmatch '<script[^>]+src=' -and $html -notmatch '\bfetch\s*\(') 'Report has no runtime script dependencies or pricing fetches'
    Assert-True ($html -notmatch 'custom.disc|discount.percent') 'Custom discount is not offered'
    $csvPath = Join-Path $summary 'pricing-options.csv'
    $csv = @(Import-Csv -LiteralPath $csvPath)
    Assert-True ($csv.Count -eq 4) 'Only Ready targets are exported, including Ready with warnings'
    Assert-True (@($csv | Where-Object { $_.Compatibility -ne 'Ready' -or $_.ReadyWithWarnings -ne '1' -or $_.Region -ne 'eastus' }).Count -eq 0) 'Ready status, warnings and selected region are retained'
    $sqlRow = $csv | Where-Object ServerName -eq 'demo-0'
    Assert-True ($sqlRow.InstanceName -eq 'ERP, "East"' -and $sqlRow.SKU -eq $cases[0].Recommendation) 'CSV quoting preserves named instances and full SKU text'
    Assert-True ($sqlRow.PAYG_MonthlyUSD -eq '888.00' -and $sqlRow.PAYG_AHB_MonthlyUSD -eq '596.00' -and
        $sqlRow.RI1Year_MonthlyUSD -eq '704.00' -and $sqlRow.RI1Year_AHB_MonthlyUSD -eq '412.00' -and
        $sqlRow.RI3Year_MonthlyUSD -eq '570.67' -and $sqlRow.RI3Year_AHB_MonthlyUSD -eq '278.67' -and
        $sqlRow.DatabaseSavingsPlan1Year_MonthlyUSD -eq '742.00' -and $sqlRow.DatabaseSavingsPlan1Year_AHB_MonthlyUSD -eq '450.00') 'All eight SQL pricing columns have invariant monthly USD amounts'
    Assert-True ($sqlRow.PAYG_Details -like '*meter*' -and $sqlRow.PAYG_AHB_Details -like '*eligible SQL Server licenses*' -and
        $sqlRow.Scope -like '*not all databases*' -and $sqlRow.Currency -eq 'USD' -and $sqlRow.HoursPerMonth -eq '730' -and
        $sqlRow.PricingSnapshotUtc -match 'T.*\+00:00$') 'CSV contains meter provenance, AHB eligibility and financial assumptions with an ISO UTC timestamp'
    $vmRow = $csv | Where-Object ServerName -eq 'demo-2'
    Assert-True ($vmRow.DatabaseSavingsPlan1Year_MonthlyUSD -eq 'Unavailable' -and
        $vmRow.DatabaseSavingsPlan1Year_AHB_MonthlyUSD -eq 'Unavailable' -and
        $vmRow.DatabaseSavingsPlan1Year_Details -like '*does not apply*') 'Inapplicable VM plans have an explicit reason, never zero'
    Assert-True (($csv | Where-Object ServerName -eq 'demo-3').PAYG_Details -like '*Hardware is unspecified*') 'Missing assumptions remain visible for Ready targets'
    Assert-True ($html -match "href='pricing-options.csv'") 'HTML links to the generated offline CSV'
    $instances = @(Import-Csv (Join-Path $summary 'instance-assessment-summary.csv'))
    $before = $script:requests.Count
    Export-SummaryPricingCsv -Instances $instances -Snapshot $json -Regions EastUS,EASTUS,missingregion -Path $csvPath
    $multiRegion = @(Import-Csv -LiteralPath $csvPath)
    Assert-True ($multiRegion.Count -eq 8 -and $script:requests.Count -eq $before) 'Multiple regions are normalized and deduplicated without additional network requests'
    Assert-True (@($multiRegion | Where-Object { $_.Region -eq 'missingregion' -and $_.PAYG_MonthlyUSD -eq 'Unavailable' }).Count -eq 4) 'Missing regional meters still export Ready targets with unavailable costs'
    Export-SummaryPricingCsv -Instances $instances -Snapshot $json -Path $csvPath
    Assert-True (@(Import-Csv -LiteralPath $csvPath).Count -eq 4) 'Omitted regions use available public compute snapshot regions'
    Export-SummaryPricingCsv -Instances $instances -Snapshot $offline -Regions eastus -Path $csvPath
    Assert-True (@(Import-Csv -LiteralPath $csvPath | Where-Object { $_.PAYG_MonthlyUSD -ne 'Unavailable' }).Count -eq 0) 'SkipPricing exports unavailable options rather than invented prices'
    Export-SummaryPricingCsv -Instances @() -Snapshot $json -Regions eastus -Path $csvPath -WarningAction SilentlyContinue
    Assert-True (@(Import-Csv -LiteralPath $csvPath).Count -eq 0 -and (Get-Content -LiteralPath $csvPath -First 1) -like '*PAYG_MonthlyUSD*') 'Empty results replace stale prices with a header-only CSV'
    $originalCulture = [Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]'de-DE'
        Export-SummaryPricingCsv -Instances $instances -Snapshot $json -Regions eastus -Path $csvPath
        Assert-True ((Import-Csv -LiteralPath $csvPath | Where-Object ServerName -eq 'demo-0').PAYG_MonthlyUSD -eq '888.00') 'CSV prices use decimal points regardless of shell locale'
    } finally {
        [Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture
    }
    $browserTests = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'summary-pricing.browser-tests.js') -Raw
    $html.Replace('</body>', "<script>$browserTests</script></body>") | Set-Content -LiteralPath $htmlPath -Encoding UTF8
    Write-Host "Pricing snapshot tests passed on PowerShell $($PSVersionTable.PSVersion)."
    Write-Host "Browser test report: $htmlPath"
} finally {
    if ($KeepArtifacts) {
        Write-Host "Test artifacts retained at: $testRoot"
    } elseif (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
