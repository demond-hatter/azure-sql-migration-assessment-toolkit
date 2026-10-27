function Get-SummaryPricingKey {
    param([string]$Target, [string]$Recommendation, [string]$SourceSqlEdition)
    $key = "$Target|$Recommendation"
    if ($Target -eq 'AzureSqlVirtualMachine' -and $SourceSqlEdition) { $key += "|SourceSqlEdition:$SourceSqlEdition" }
    return $key
}

function Get-SummaryPricingSpec {
    param([string]$Target, [string]$Recommendation, [string]$SourceSqlEdition)
    $spec = [ordered]@{
        key=(Get-SummaryPricingKey $Target $Recommendation $SourceSqlEdition); target=$Target; cores=0; storageGb=$null
        computeProduct=''; licenseProduct=''; storageProduct=''; storageMeter=''
        armSku=''; edition=''; os=''; disks=@(); needsHardware=$false; error=''; notes=@()
        sourceSqlEdition=$SourceSqlEdition; editionSource=''; editionError=''
    }
    if ([string]::IsNullOrWhiteSpace($Recommendation)) {
        $spec.error = 'No SKU recommendation.'
        return [pscustomobject]$spec
    }
    if ($Target -eq 'AzureSqlVirtualMachine') {
        $sizePattern = '[A-Z]+\d+(?:-\d+)?[A-Z0-9]*(?:_[A-Z0-9]+)*'
        $vm = [regex]::Match($Recommendation, "(?i)\bStandard_(?<size>$sizePattern)\b")
        if (-not $vm.Success) {
            $vm = [regex]::Match($Recommendation, "(?i)\bCompute:\s*(?:[A-Z0-9]+Family\s*-\s*)?(?<size>$sizePattern)\s+-\s+\d+\s+Available\s+vCPU\b")
        }
        if (-not $vm.Success) {
            $vm = [regex]::Match($Recommendation, '(?i)\b(?<size>[A-Z]+\d+(?:-\d+)?[A-Z0-9]*(?:_[A-Z0-9]+)*_v\d+)\b')
        }
        if (-not $vm.Success) {
            $spec.error = 'The recommendation does not identify an ARM VM size.'
            return [pscustomobject]$spec
        }
        $spec.armSku = 'Standard_' + $vm.Groups['size'].Value
        $cpu = [regex]::Match($spec.armSku, '(?i)^Standard_[A-Z]+(?<cores>\d+)(?:-(?<constrained>\d+))?')
        $availableCpu = [regex]::Match($Recommendation, '(?i)\b(?<cores>\d+)\s+Available\s+vCPU\b')
        $spec.cores = if ($availableCpu.Success) { [int]$availableCpu.Groups['cores'].Value }
            elseif ($cpu.Groups['constrained'].Success) { [int]$cpu.Groups['constrained'].Value }
            else { [int]$cpu.Groups['cores'].Value }
        if ($Recommendation -match '(?i)\b(Standard|Enterprise|Web)\s+Edition\b') {
            $spec.edition = $Matches[1]
            $spec.editionSource = 'SKU recommendation'
        } elseif ($SourceSqlEdition -match '(?i)^\s*(Standard|Enterprise|Web)(?:\s|$)') {
            $spec.edition = $Matches[1]
            $spec.editionSource = 'Source assessment ServerEdition'
        } elseif ($SourceSqlEdition) {
            $spec.editionError = "Source assessed SQL edition '$SourceSqlEdition' has no supported public VM SQL license mapping; no edition was assumed."
        } else {
            $spec.editionError = 'SQL edition is missing from both the SKU recommendation and the source assessment.'
        }
        if ($Recommendation -match '(?i)\bWindows\b') { $spec.os = 'Windows' }
        elseif ($Recommendation -match '(?i)\bLinux\b') { $spec.os = 'Linux' }
        else { $spec.os = 'Windows' }
        foreach ($disk in [regex]::Matches($Recommendation, '(?i)(?:(?<count>\d+)\s*x\s*)?\b(?<sku>P\d+|E\d+|S\d+)\s*(?<redundancy>LRS|ZRS)?\b')) {
            $spec.disks += [pscustomobject]@{
                sku=$disk.Groups['sku'].Value.ToUpperInvariant()
                count=if ($disk.Groups['count'].Success) { [int]$disk.Groups['count'].Value } else { 1 }
                redundancy=if ($disk.Groups['redundancy'].Success) { $disk.Groups['redundancy'].Value.ToUpperInvariant() } else { '' }
            }
        }
        $spec.notes = @('VM OS/data disks are included only when a disk SKU, count and redundancy are specified. Unspecified disks, disk transactions and burst charges are excluded.')
        if ($Recommendation -notmatch '(?i)\bWindows\b|\bLinux\b') {
            $spec.notes += 'VM OS unspecified; Windows Server assumed, including Windows Server licensing.'
        }
        if ($spec.edition) { $spec.notes += "SQL edition: $($spec.edition) ($($spec.editionSource))." }
        elseif ($spec.editionError) { $spec.notes += $spec.editionError }
        return [pscustomobject]$spec
    }
    $cores = [regex]::Match($Recommendation, '(?i)\b(?<cores>\d+)\s*(?:v?cores?)\b')
    if (-not $cores.Success -or $Recommendation -match '(?i)serverless|elastic pool|DTU') {
        $spec.error = 'A supported provisioned vCore recommendation is required (serverless, DTU and elastic pool estimates are not inferred).'
        return [pscustomobject]$spec
    }
    $spec.cores = [int]$cores.Groups['cores'].Value
    $storage = [regex]::Match($Recommendation, '(?i)\bStorage:\s*(?<gb>\d+(?:\.\d+)?)\s*GB\b')
    if ($storage.Success) { $spec.storageGb = [double]::Parse($storage.Groups['gb'].Value, [cultureinfo]::InvariantCulture) }
    $tier = if ($Recommendation -match '(?i)NextGenGeneralPurpose|General\s*Purpose') { 'General Purpose' }
        elseif ($Recommendation -match '(?i)Business\s*Critical') { 'Business Critical' }
        elseif ($Recommendation -match '(?i)Hyperscale') { 'Hyperscale' }
        else { '' }
    if (-not $tier) {
        $spec.error = 'The SQL service tier could not be identified.'
        return [pscustomobject]$spec
    }
    $hardware = if ($Recommendation -match '(?i)Premium\s*Series\s*Memory\s*Optimized') { 'Premium Series Memory Optimized Compute' }
        elseif ($Recommendation -match '(?i)Premium\s*Series') { 'Premium Series Compute' }
        elseif ($Recommendation -match '(?i)\bGen([45])\b') { "Compute Gen$($Matches[1])" }
        elseif ($Recommendation -match '(?i)\bDC[- ]?Series\b') { 'Compute DC-Series' }
        elseif ($Recommendation -match '(?i)\bFSv2\b') { 'Compute FSv2 Series' }
        else { '' }
    if (-not $hardware) {
        if ($Recommendation -match '(?i)\bGen\d+\b|Compute:\s*.+?\s+-\s+(?:NextGenGeneralPurpose|General\s*Purpose|Business\s*Critical|Hyperscale)\b') {
            $spec.error = 'The recommendation specifies hardware that is not supported by this pricing mapping.'
            return [pscustomobject]$spec
        }
        $spec.needsHardware = $true
        $hardware = 'Compute Gen5'
    }
    if ($Target -eq 'AzureSqlManagedInstance') {
        $prefix = "SQL Managed Instance $tier"
    } else {
        $prefix = "SQL Database Single/Elastic Pool $tier"
    }
    $spec.computeProduct = "$prefix - $hardware"
    $spec.licenseProduct = "$prefix - SQL License"
    $spec.storageProduct = "$prefix - Storage"
    $spec.storageMeter = "$tier Data Stored"
    if ($tier -eq 'Hyperscale') {
        if ($Target -eq 'AzureSqlManagedInstance') { $spec.error = 'Managed Instance does not have a Hyperscale tier.' }
        $spec.computeProduct = "SQL Database SingleDB/Elastic Pool Hyperscale - $hardware"
        $spec.licenseProduct = 'SQL Database SingleDB/Elastic Pool Hyperscale - SQL License'
        $spec.storageProduct = 'SQL Database SingleDB Hyperscale - Storage'
        $spec.storageMeter = 'Hyperscale Data Stored'
        $spec.notes += 'Hyperscale replicas, log and backup charges are excluded.'
    }
    if ($Recommendation -match '(?i)NextGenGeneralPurpose') {
        $spec.notes += 'Next-gen General Purpose uses General Purpose baseline rates; extra IOPS and memory are excluded.'
    }
    if ($Recommendation -match '(?i)zone.?redundan') {
        $spec.error = 'Zone-redundant recommendations require separate meters and are not estimated by this report.'
    }
    return [pscustomobject]$spec
}

function Get-SummaryRetailPrices {
    param([Parameter(Mandatory)][string]$Filter)
    $url = 'https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&currencyCode=%27USD%27&meterRegion=%27primary%27&$filter=' + [uri]::EscapeDataString($Filter)
    $seen = @{}
    while ($url) {
        $uri = [uri]$url
        if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'prices.azure.com' -or $uri.AbsolutePath -ne '/api/retail/prices' -or $seen.ContainsKey($url)) {
            throw 'The Azure Retail Prices API returned an invalid pagination link.'
        }
        $seen[$url] = $true
        $response = Invoke-RestMethod -Uri $url -TimeoutSec 90 -ErrorAction Stop
        if ($null -eq $response.PSObject.Properties['Items']) { throw 'The Azure Retail Prices API response has no Items collection.' }
        foreach ($item in $response.Items) {
            if ($item.currencyCode -ne 'USD') { throw 'The Azure Retail Prices API returned an unexpected currency.' }
            $item
        }
        $url = $response.NextPageLink
    }
}

function New-SummaryPricingSnapshot {
    [CmdletBinding()]
    param([array]$Recommendations, [string[]]$Regions, [switch]$SkipPricing)
    $specs = @($Recommendations | ForEach-Object {
        $sourceEdition = if ($_.PSObject.Properties['SourceSqlEdition']) { $_.SourceSqlEdition } else { '' }
        Get-SummaryPricingSpec $_.Target $_.Recommendation $sourceEdition
    } | Sort-Object key -Unique)
    $snapshot = [ordered]@{
        currency='USD'; hoursPerMonth=730; generatedUtc=(Get-Date).ToUniversalTime().ToString('o')
        skipped=[bool]$SkipPricing; specs=$specs; items=@(); errors=@()
    }
    if ($SkipPricing) { return [pscustomobject]$snapshot }
    $filters = @{}
    foreach ($spec in $specs | Where-Object { -not $_.error }) {
        if ($spec.target -eq 'AzureSqlVirtualMachine') {
            $retailSku = $spec.armSku -replace '^Standard_', '' -replace '_', ' '
            $filters["serviceName eq 'Virtual Machines' and armSkuName eq '$($spec.armSku)' and (skuName eq '$retailSku' or skuName eq '$($spec.armSku)')"] = $true
            $licenseSku = if ($spec.cores -le 4) { '1-4 vCPU VM' } else { "$($spec.cores) vCPU VM" }
            foreach ($edition in @('Standard', 'Enterprise', 'Web')) {
                $filters["serviceName eq 'Virtual Machines Licenses' and productName eq 'SQL Server $edition' and skuName eq '$licenseSku' and priceType eq 'Consumption'"] = $true
            }
            foreach ($disk in $spec.disks | Where-Object redundancy) {
                $diskProduct = switch ($disk.sku.Substring(0, 1)) {
                    'P' { 'Premium SSD Managed Disks' }
                    'E' { 'Standard SSD Managed Disks' }
                    'S' { 'Standard HDD Managed Disks' }
                }
                $filters["serviceName eq 'Storage' and productName eq '$diskProduct' and skuName eq '$($disk.sku) $($disk.redundancy)' and priceType eq 'Consumption'"] = $true
            }
        } else {
            $service = if ($spec.target -eq 'AzureSqlManagedInstance') { 'SQL Managed Instance' } else { 'SQL Database' }
            $filters["serviceName eq '$service' and productName eq '$($spec.computeProduct)' and meterName eq 'vCore' and (skuName eq 'vCore' or skuName eq '1 vCore')"] = $true
            $filters["serviceName eq '$service' and productName eq '$($spec.licenseProduct)' and armRegionName eq 'Global' and priceType eq 'Consumption'"] = $true
            $filters["serviceName eq '$service' and productName eq '$($spec.storageProduct)' and meterName eq '$($spec.storageMeter)' and priceType eq 'Consumption'"] = $true
        }
    }
    $regionFilter = if ($Regions.Count -gt 0) {
        '(' + (($Regions | ForEach-Object { "armRegionName eq '$($_.ToLowerInvariant().Replace("'", "''"))'" } | Select-Object -Unique) -join ' or ') + ')'
    } else { '' }
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($filter in $filters.Keys | Sort-Object) {
        $query = if ($regionFilter -and $filter -notmatch "SQL License|Virtual Machines Licenses") { "($filter) and $regionFilter" } else { $filter }
        Write-Verbose "Fetching retail prices: $query"
        try {
            foreach ($item in @(Get-SummaryRetailPrices $query)) {
                if ($item.type -eq 'DevTestConsumption') { continue }
                $items.Add(($item | Select-Object currencyCode,serviceName,armRegionName,location,productName,skuName,meterName,armSkuName,type,reservationTerm,unitOfMeasure,retailPrice,tierMinimumUnits,effectiveStartDate,meterId,savingsPlan))
            }
        } catch {
            $message = "Pricing query failed ($query): $($_.Exception.Message)"
            Write-Warning $message
            $snapshot.errors += $message
        }
    }
    $snapshot.items = @($items.ToArray())
    return [pscustomobject]$snapshot
}

function Get-SummaryPricingMeter {
    param($Snapshot, [scriptblock]$Predicate, [string]$Region, [string]$Type='Consumption', [string]$Term='')
    $latest = @{}
    foreach ($item in $Snapshot.items) {
        if ($item.type -cne $Type -or ($Region -and $item.armRegionName -cne $Region) -or
            ($Term -and $item.reservationTerm -cne $Term) -or [double]$item.tierMinimumUnits -ne 0 -or
            [datetimeoffset]$item.effectiveStartDate -gt [datetimeoffset]$Snapshot.generatedUtc -or
            -not (& $Predicate $item)) { continue }
        $key = "$($item.meterId)|$($item.skuName)|$($item.reservationTerm)"
        if (-not $latest.ContainsKey($key) -or
            [datetimeoffset]$item.effectiveStartDate -gt [datetimeoffset]$latest[$key].effectiveStartDate) {
            $latest[$key] = $item
        }
    }
    $values = @($latest.Values)
    if ($values.Count -eq 0) { throw "No matching $Type meter ($Term) in the embedded snapshot for region '$Region'." }
    $signatures = @($values | ForEach-Object {
        ConvertTo-Json -InputObject @($_.retailPrice, $_.unitOfMeasure, $_.savingsPlan) -Depth 5 -Compress
    } | Select-Object -Unique)
    if ($signatures.Count -ne 1) { throw 'Ambiguous retail meters; no price was guessed.' }
    $price = $values[0].retailPrice
    if ($null -eq $price -or [double]::IsNaN($price) -or [double]::IsInfinity($price) -or $price -lt 0) {
        throw 'Invalid retail meter price.'
    }
    return $values[0]
}

function Get-SummaryMonthlyPrice {
    param($Meter, [double]$Quantity=1, [string]$Term='', [double]$Hours=730)
    if ($Quantity -le 0) { throw 'A positive billing quantity is required.' }
    if ($Term) {
        if ($Meter.unitOfMeasure -cne '1 Hour') { throw "Unsupported reservation billing unit: $($Meter.unitOfMeasure)" }
        $months = if ($Term -eq '1 Year') { 12 } else { 36 }
        return $Meter.retailPrice * $Quantity / $months
    }
    if ($Meter.unitOfMeasure -ceq '1 Hour') { return $Meter.retailPrice * $Quantity * $Hours }
    if (@('1 GB/Month', '1/Month', '1 Disk/Month') -ccontains $Meter.unitOfMeasure) { return $Meter.retailPrice * $Quantity }
    throw "Unsupported billing unit: $($Meter.unitOfMeasure)"
}

function Get-SummaryPriceEstimate {
    param($Snapshot, $Spec, [string]$Region, [ValidateSet('payg','ri1','ri3','dbsp1')][string]$Plan='payg', [switch]$Ahb)
    $components = [System.Collections.Generic.List[object]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()
    foreach ($note in $Spec.notes) { $notes.Add($note) }
    function Add-PriceComponent {
        param([string]$Label, [double]$Amount, $Meter)
        if ([double]::IsNaN($Amount) -or [double]::IsInfinity($Amount) -or $Amount -lt 0) { throw 'Invalid component price.' }
        $components.Add([pscustomobject]@{ label=$Label; amount=$Amount; meter=$Meter.meterId; product=$Meter.productName })
    }
    function Get-Monthly {
        param($Meter, [double]$Quantity=1, [string]$Term='')
        Get-SummaryMonthlyPrice -Meter $Meter -Quantity $Quantity -Term $Term -Hours $Snapshot.hoursPerMonth
    }
    try {
        if ($Spec.error) { throw $Spec.error }
        if (-not $Region) { throw 'Select an Azure region.' }
        if ($Snapshot.skipped) { throw 'Pricing was skipped. Regenerate the summary without -SkipPricing.' }
        if ($Spec.needsHardware) { throw 'Hardware is unspecified. CSV estimates require a recommendation with explicit hardware; Gen5 is not assumed.' }
        $term = switch ($Plan) { 'ri1' { '1 Year' } 'ri3' { '3 Years' } default { '' } }
        if ($Spec.target -eq 'AzureSqlVirtualMachine') {
            if ($Plan -eq 'dbsp1') { throw 'The database savings plan does not apply to SQL Server on Azure VMs.' }
            $os = if ($Spec.os) { $Spec.os } else { 'Windows' }
            if (-not $Spec.os) {
                $assumption = 'VM OS unspecified; Windows Server assumed, including Windows Server licensing.'
                if (-not $notes.Contains($assumption)) { $notes.Add($assumption) }
            }
            $vmSkuNames = @($Spec.armSku, ($Spec.armSku -replace '^Standard_', '' -replace '_', ' '))
            $linux = { param($item) $item.armSkuName -eq $Spec.armSku -and $item.skuName -in $vmSkuNames -and -not $item.productName.EndsWith(' Windows') }
            $windows = { param($item) $item.armSkuName -eq $Spec.armSku -and $item.skuName -in $vmSkuNames -and $item.productName.EndsWith(' Windows') }
            $base = Get-SummaryPricingMeter $Snapshot $linux $Region
            if ($term) {
                $compute = Get-SummaryPricingMeter $Snapshot $linux $Region 'Reservation' $term
                Add-PriceComponent "VM compute ($term RI, amortized)" (Get-Monthly $compute 1 $term) $compute
                if ($os -eq 'Windows') {
                    $win = Get-SummaryPricingMeter $Snapshot $windows $Region
                    Add-PriceComponent 'Windows Server license (not covered by SQL Hybrid Benefit)' ((Get-Monthly $win) - (Get-Monthly $base)) $win
                }
            } else {
                $predicate = if ($os -eq 'Windows') { $windows } else { $linux }
                $compute = Get-SummaryPricingMeter $Snapshot $predicate $Region
                Add-PriceComponent 'VM compute (including Windows license when applicable)' (Get-Monthly $compute) $compute
            }
            if (-not $Ahb) {
                if (-not $Spec.edition) { throw $Spec.editionError }
                $licenseSku = if ($Spec.cores -le 4) { '1-4 vCPU VM' } else { "$($Spec.cores) vCPU VM" }
                $sql = Get-SummaryPricingMeter $Snapshot {
                    param($item) $item.productName -eq "SQL Server $($Spec.edition)" -and $item.skuName -ceq $licenseSku
                } ''
                Add-PriceComponent "SQL Server $($Spec.edition) license" (Get-Monthly $sql) $sql
            }
            if (-not $Spec.disks.Count) { $notes.Add('No managed-disk SKUs were specified; all VM storage is excluded.') }
            foreach ($disk in $Spec.disks) {
                if (-not $disk.redundancy) { $notes.Add("$($disk.sku) redundancy unspecified; this disk is excluded."); continue }
                try {
                    $storage = Get-SummaryPricingMeter $Snapshot {
                        param($item) $item.skuName -ceq "$($disk.sku) $($disk.redundancy)" -and $item.meterName -ceq "$($disk.sku) $($disk.redundancy) Disk"
                    } $Region
                    Add-PriceComponent "$($disk.count) x $($disk.sku) $($disk.redundancy) disk" (Get-Monthly $storage $disk.count) $storage
                } catch { $notes.Add("Disk storage excluded: $($_.Exception.Message)") }
            }
        } else {
            $computeMatch = { param($item) $item.productName -ceq $Spec.computeProduct -and $item.meterName -ceq 'vCore' -and $item.skuName -ceq 'vCore' }
            if ($term) {
                $compute = Get-SummaryPricingMeter $Snapshot $computeMatch $Region 'Reservation' $term
                Add-PriceComponent "Compute ($term RI, amortized)" (Get-Monthly $compute $Spec.cores $term) $compute
            } else {
                $hasVcore = @($Snapshot.items | Where-Object {
                    (& $computeMatch $_) -and $_.armRegionName -ceq $Region -and $_.type -ceq 'Consumption'
                }).Count -gt 0
                if (-not $hasVcore) {
                    $computeMatch = { param($item) $item.productName -ceq $Spec.computeProduct -and $item.meterName -ceq 'vCore' -and $item.skuName -ceq '1 vCore' }
                }
                $compute = Get-SummaryPricingMeter $Snapshot $computeMatch $Region
                if ($Plan -eq 'dbsp1') {
                    $plans = @($compute.savingsPlan | Where-Object { $_.term -ceq '1 Year' })
                    if ($plans.Count -ne 1 -or $null -eq $plans[0].retailPrice -or
                        [double]::IsNaN($plans[0].retailPrice) -or [double]::IsInfinity($plans[0].retailPrice) -or $plans[0].retailPrice -lt 0) {
                        throw 'No unambiguous 1-year database savings-plan rate for this compute meter.'
                    }
                    Add-PriceComponent 'Compute (1-year database savings plan)' ($plans[0].retailPrice * $Spec.cores * $Snapshot.hoursPerMonth) $compute
                } else {
                    Add-PriceComponent 'Compute (PAYG)' (Get-Monthly $compute $Spec.cores) $compute
                }
            }
            if (-not $Ahb) {
                $sql = Get-SummaryPricingMeter $Snapshot {
                    param($item) $item.productName -ceq $Spec.licenseProduct -and $item.skuName -ceq 'vCore' -and $item.unitOfMeasure -ceq '1 Hour'
                } 'Global'
                Add-PriceComponent 'SQL license (not discounted by RI or database savings plan)' (Get-Monthly $sql $Spec.cores) $sql
            }
            if ($null -eq $Spec.storageGb -or $Spec.storageGb -le 0) {
                $notes.Add('No positive storage quantity was specified; storage is excluded.')
            } else {
                try {
                    $storage = Get-SummaryPricingMeter $Snapshot {
                        param($item) $item.productName -ceq $Spec.storageProduct -and $item.meterName -ceq $Spec.storageMeter
                    } $Region
                    Add-PriceComponent "$($Spec.storageGb) GB recommended storage" (Get-Monthly $storage $Spec.storageGb) $storage
                } catch { $notes.Add("Storage excluded: $($_.Exception.Message)") }
            }
        }
        if ($Ahb) { $notes.Add('SQL license charge waived: assumes sufficient eligible SQL Server licenses with Software Assurance or subscription rights. Windows Server licensing is not waived.') }
        return [pscustomobject]@{ amount=($components | Measure-Object amount -Sum).Sum; components=@($components.ToArray()); notes=@($notes.ToArray()); error='' }
    } catch {
        return [pscustomobject]@{ amount=$null; components=@(); notes=@($notes.ToArray()); error=$_.Exception.Message }
    }
}

function Export-SummaryPricingCsv {
    param([array]$Instances, $Snapshot, [string[]]$Regions, [Parameter(Mandatory)][string]$Path)
    $regionsToExport = if ($Regions.Count) {
        @($Regions | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
    } else {
        @($Snapshot.items | Where-Object {
            $_.armRegionName -and $_.armRegionName -notmatch '^(global$|us gov$|usgov|usdod|china)' -and
            $_.unitOfMeasure -ceq '1 Hour' -and $_.type -ceq 'Consumption' -and $_.serviceName -cne 'Virtual Machines Licenses'
        } | Select-Object -ExpandProperty armRegionName -Unique | Sort-Object)
    }
    $options = @(
        @{ name='PAYG'; plan='payg'; ahb=$false }, @{ name='PAYG_AHB'; plan='payg'; ahb=$true }
        @{ name='RI1Year'; plan='ri1'; ahb=$false }, @{ name='RI1Year_AHB'; plan='ri1'; ahb=$true }
        @{ name='RI3Year'; plan='ri3'; ahb=$false }, @{ name='RI3Year_AHB'; plan='ri3'; ahb=$true }
        @{ name='DatabaseSavingsPlan1Year'; plan='dbsp1'; ahb=$false }, @{ name='DatabaseSavingsPlan1Year_AHB'; plan='dbsp1'; ahb=$true }
    )
    $template = [ordered]@{
        ServerName=''; InstanceName=''; DisplayName=''; Target=''; Compatibility=''; ReadinessSource=''; ReadyWithWarnings=0; SKU=''
        SourceSqlEdition=''; VmSqlEdition=''; VmSqlEditionSource=''
        Region=''; Currency=$Snapshot.currency; HoursPerMonth=$Snapshot.hoursPerMonth
        PricingSnapshotUtc=([datetimeoffset]$Snapshot.generatedUtc).ToUniversalTime().ToString('o')
        Scope='Monthly subtotal for one recommended resource, not all databases. Excludes backup, networking, tax, support, HA/DR replicas and usage-based IO. Full utilization of commitments assumed. Linux paid distribution licensing excluded. Not a quote.'
        PricingQueryWarnings=($Snapshot.errors -join ' | ')
    }
    foreach ($option in $options) {
        $template["$($option.name)_MonthlyUSD"] = ''
        $template["$($option.name)_Details"] = ''
    }
    $specs = @{}
    foreach ($spec in $Snapshot.specs) { $specs[$spec.key] = $spec }
    $cache = @{}
    $rows = @(
        foreach ($instance in $Instances) {
            foreach ($target in @('AzureSqlDatabase', 'AzureSqlManagedInstance', 'AzureSqlVirtualMachine')) {
                $prefix = if ($target -eq 'AzureSqlVirtualMachine') { 'AzureSqlIaaS' } else { $target }
                if (($instance."${prefix}Compatibility" -replace '[\s_-]', '') -ne 'Ready') { continue }
                $recommendation = $instance."${prefix}SkuRecommendation"
                $sourceEdition = if ($instance.PSObject.Properties['SourceSqlEdition']) { $instance.SourceSqlEdition } else { '' }
                $spec = $specs[(Get-SummaryPricingKey $target $recommendation $sourceEdition)]
                if ($null -eq $spec) { throw "Pricing specification missing for Ready target '$target'." }
                foreach ($region in $regionsToExport) {
                    $row = [ordered]@{}
                    foreach ($key in $template.Keys) { $row[$key] = $template[$key] }
                    $row.ServerName = $instance.ServerName
                    $row.InstanceName = $instance.InstanceName
                    $row.DisplayName = $instance.DisplayName
                    $row.Target = $target
                    $row.Compatibility = 'Ready'
                    $sourceProperty = if ($target -eq 'AzureSqlVirtualMachine') { $instance.PSObject.Properties['AzureSqlIaaSReadinessSource'] } else { $null }
                    $row.ReadinessSource = if ($sourceProperty) { $sourceProperty.Value } elseif ($target -eq 'AzureSqlVirtualMachine') {
                        'Not recorded in instance summary'
                    } else { 'Explicit JSON target readiness' }
                    $row.ReadyWithWarnings = $instance."${prefix}ReadyWithWarnings"
                    $row.SKU = $recommendation
                    $row.SourceSqlEdition = $sourceEdition
                    if ($target -eq 'AzureSqlVirtualMachine') {
                        $row.VmSqlEdition = $spec.edition
                        $row.VmSqlEditionSource = $spec.editionSource
                    }
                    $row.Region = $region
                    foreach ($option in $options) {
                        $key = "$($spec.key)|$region|$($option.name)"
                        if (-not $cache.ContainsKey($key)) {
                            $cache[$key] = Get-SummaryPriceEstimate -Snapshot $Snapshot -Spec $spec -Region $region -Plan $option.plan -Ahb:$option.ahb
                        }
                        $result = $cache[$key]
                        $row["$($option.name)_MonthlyUSD"] = if ($result.error) { 'Unavailable' } else {
                            $result.amount.ToString('F2', [cultureinfo]::InvariantCulture)
                        }
                        $row["$($option.name)_Details"] = (@(
                            if ($result.error) { $result.error }
                            foreach ($component in $result.components) {
                                "$($component.label): $($component.amount.ToString('F2', [cultureinfo]::InvariantCulture)) USD/month; product $($component.product); meter $($component.meter)"
                            }
                            $result.notes
                        ) -join ' | ')
                    }
                    [pscustomobject]$row
                }
            }
        }
    )
    if ($rows.Count) {
        $rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
    } else {
        ([pscustomobject]$template | ConvertTo-Csv -NoTypeInformation | Select-Object -First 1) | Set-Content -LiteralPath $Path -Encoding UTF8
        Write-Warning 'Pricing options CSV has headers only: no Ready targets or no pricing regions. Specify -PricingRegion to include a region even when prices are unavailable or skipped.'
    }
}
