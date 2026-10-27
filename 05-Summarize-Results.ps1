[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResultsRoot,
    [string]$SummaryFolder = (Join-Path $ResultsRoot -ChildPath 'summary'),
    [ValidatePattern('^[a-zA-Z0-9]+$')][string[]]$PricingRegion = @(),
    [switch]$SkipPricing
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'SummaryPricing.ps1')
if (-not (Test-Path $ResultsRoot)) { throw "Results folder not found: $ResultsRoot" }
$ResultsRoot = (Resolve-Path $ResultsRoot).Path
if (-not (Test-Path -LiteralPath $SummaryFolder)) {
    New-Item -ItemType Directory -Path $SummaryFolder -Force | Out-Null
} elseif (-not (Test-Path -LiteralPath $SummaryFolder -PathType Container)) {
    throw "Summary folder path is not a directory: $SummaryFolder"
}
$SummaryFolder = (Resolve-Path -LiteralPath $SummaryFolder).Path
if ([System.IO.Path]::GetPathRoot($ResultsRoot) -ne [System.IO.Path]::GetPathRoot($SummaryFolder)) {
    throw 'ResultsRoot and SummaryFolder must be on the same drive or network share so report links can be relative.'
}

$files = Get-ChildItem $ResultsRoot -Recurse -File
$catalog = $files | Select-Object @{n='RelativePath';e={$_.FullName.Substring($ResultsRoot.Length).TrimStart('\','/')}},Extension,Length,LastWriteTimeUtc
$catalog | Export-Csv (Join-Path $SummaryFolder 'file-catalog.csv') -NoTypeInformation

function Get-PropertyValue {
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Get-NormalizedIdentity {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return (($Value -replace '^(?i)tcp:', '') -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
}

function Get-SourceMetadata {
    param([Parameter(Mandatory)][System.IO.FileInfo]$ReportFile)
    $directory = $ReportFile.Directory
    while ($directory -and $directory.FullName.StartsWith($ResultsRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        $sourceFile = Get-ChildItem $directory.FullName -File -Filter '*-source.csv' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($sourceFile) {
            return Import-Csv $sourceFile.FullName | Select-Object -First 1
        }
        $directory = $directory.Parent
    }
    return $null
}

function Get-AssessmentTargetNames {
    param([Parameter(Mandatory)][string]$Target)
    if ($Target -eq 'AzureSqlVirtualMachine') {
        return @('AzureSqlVirtualMachine', 'SqlServerOnAzureVM', 'AzureSqlIaaS')
    }
    return @($Target)
}

function Get-TargetReadiness {
    param($Object, [Parameter(Mandatory)][string]$Target)
    $targetReadinesses = Get-PropertyValue $Object 'TargetReadinesses'
    foreach ($name in (Get-AssessmentTargetNames $Target)) {
        $readiness = Get-PropertyValue $targetReadinesses $name
        if ($null -ne $readiness) { return $readiness }
    }
    return $null
}

function Test-AssessmentCompleted {
    param($Object)
    return (Get-PropertyValue $Object 'Status') -eq 'Completed' -and
        @(Get-PropertyValue $Object 'Errors' | Where-Object { $null -ne $_ }).Count -eq 0
}

function Get-ReadinessStatus {
    param($Server, [Parameter(Mandatory)][string]$Target, [switch]$CompletedAssessment)
    $readiness = Get-TargetReadiness $Server $Target
    if ($null -eq $readiness) {
        if ($Target -ne 'AzureSqlVirtualMachine' -or -not $CompletedAssessment -or -not (Test-AssessmentCompleted $Server)) {
            return 'Not assessed'
        }
        # Native VM reports omit readiness when no VM-specific issues exist.
        if ($null -ne $Server.PSObject.Properties['Databases']) {
            $databases = @(Get-PropertyValue $Server 'Databases' | Where-Object { $null -ne $_ })
            if ($databases.Count -eq 0) { return 'Not assessed' }
            if (@($databases | Where-Object { -not (Test-AssessmentCompleted $_) }).Count -gt 0) { return 'Not assessed' }
            $statuses = @($databases | ForEach-Object {
                Get-ReadinessStatus $_ $Target -CompletedAssessment
            })
            if (@($statuses | Where-Object { ($_ -replace '[\s_-]', '') -eq 'NotReady' }).Count -gt 0) { return 'NotReady' }
            if (@($statuses | Where-Object { $_ -ne 'Ready' }).Count -gt 0) { return 'Not assessed' }
        }
        $targetNames = Get-AssessmentTargetNames $Target
        $findings = @(Get-PropertyValue $Server 'ServerAssessments') + @(Get-PropertyValue $Server 'DatabaseAssessments')
        $blockers = @($findings | Where-Object {
            (Get-PropertyValue $_ 'AppliesToMigrationTargetPlatform') -in $targetNames -and
            (Get-PropertyValue $_ 'IssueCategory') -in @('Issue', 'BlockingIssue', 'Critical')
        })
        if ($blockers.Count -gt 0) { return 'NotReady' }
        return 'Ready'
    }
    $status = [string](Get-PropertyValue $readiness 'RecommendationStatus')
    if ([string]::IsNullOrWhiteSpace($status)) { return 'Unknown' }
    if (($status -replace '[\s_-]', '') -eq 'NotAssessed') { return 'Not assessed' }
    return $status
}

function Get-ReadyWithWarningsCount {
    param($Server, [Parameter(Mandatory)][string]$Target, [switch]$CompletedAssessment)
    $count = 0
    $targetNames = Get-AssessmentTargetNames $Target
    foreach ($database in @(Get-PropertyValue $Server 'Databases')) {
        if ($null -eq $database) { continue }
        if ((Get-ReadinessStatus $database $Target -CompletedAssessment:$CompletedAssessment) -ne 'Ready') { continue }
        $warnings = @(Get-PropertyValue $database 'DatabaseAssessments' | Where-Object {
            [string](Get-PropertyValue $_ 'IssueCategory') -eq 'Warning' -and
            [string](Get-PropertyValue $_ 'AppliesToMigrationTargetPlatform') -in $targetNames
        })
        if ($warnings.Count -gt 0) { $count++ }
    }
    return $count
}

function Get-RelativeFileLink {
    param([Parameter(Mandatory)][string]$Path)
    $summaryBase = [System.Uri]::new($SummaryFolder.TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar)
    $target = [System.Uri]::new((Resolve-Path $Path).Path)
    return $summaryBase.MakeRelativeUri($target).ToString()
}

function Get-RelatedHtmlReport {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$SourceFile,
        [Parameter(Mandatory)][string]$NamePattern
    )
    $htmlFiles = @(Get-ChildItem $SourceFile.DirectoryName -File -Filter '*.html' -ErrorAction SilentlyContinue)
    $matchingBaseName = $htmlFiles | Where-Object BaseName -eq $SourceFile.BaseName | Select-Object -First 1
    $htmlFile = if ($matchingBaseName) {
        $matchingBaseName
    } else {
        $htmlFiles | Where-Object Name -like $NamePattern | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    }
    if ($htmlFile) { return $htmlFile }
    return $null
}

function Get-RecommendationTarget {
    param([string]$RequestedTarget, [string]$Recommendation)
    if ($Recommendation -match '(?i)managed instance') { return 'AzureSqlManagedInstance' }
    if ($Recommendation -match '(?i)azure sql database') { return 'AzureSqlDatabase' }
    if ($Recommendation -match '(?i)virtual machine|azure vm|sql server on azure') { return 'AzureSqlVirtualMachine' }
    if ($RequestedTarget -ne 'Any') { return $RequestedTarget }
    return $null
}

$jsonRows = foreach ($file in $files | Where-Object Extension -eq '.json') {
    try {
        $json = Get-Content $file.FullName -Raw | ConvertFrom-Json
        function Expand-JsonLeaf($value, [string]$path) {
            if ($null -eq $value) { [pscustomobject]@{File=$file.FullName;Path=$path;Value=$null}; return }
            if ($value -is [System.Collections.IDictionary] -or $value -is [pscustomobject]) {
                foreach ($p in $value.PSObject.Properties) { Expand-JsonLeaf $p.Value "$path/$($p.Name)" }
            } elseif ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
                $i=0; foreach ($item in $value) { Expand-JsonLeaf $item "$path/$i"; $i++ }
            } else { [pscustomobject]@{File=$file.FullName;Path=$path;Value=[string]$value} }
        }
        Expand-JsonLeaf $json ''
    } catch {
        [pscustomobject]@{File=$file.FullName;Path='/ParseError';Value=$_.Exception.Message}
    }
}
$jsonRows | Export-Csv (Join-Path $SummaryFolder 'json-details.csv') -NoTypeInformation

$recommendations = foreach ($file in $files | Where-Object { $_.Name -like '*-console.txt' }) {
    $text = Get-Content $file.FullName -Raw
    $instanceMatches = [regex]::Matches($text, '(?ms)Instance name:\s*(?<instance>.+?)\r?\nSKU recommendation:\s*(?<recommendation>.+?)(?=\r?\nRecommendation reasons:|\r?\nInstance name:|\z)')
    foreach ($match in $instanceMatches) {
        $targetMatch = [regex]::Match($file.FullName, '(?i)[\\/](AzureSqlDatabase|AzureSqlManagedInstance|AzureSqlVirtualMachine|Any)[\\/]')
        $requestedTarget = if ($targetMatch.Success) { $targetMatch.Groups[1].Value } else { 'Any' }
        $recommendation = ($match.Groups['recommendation'].Value -replace '\s+',' ').Trim()
        $htmlReport = Get-RelatedHtmlReport $file '*SkuRecommendationReport*.html'
        $sourceToken = if ($targetMatch.Success) {
            Split-Path (Split-Path $file.DirectoryName -Parent) -Leaf
        } else { '' }
        [pscustomobject]@{
            SourceFile=$file.Name
            Instance=$match.Groups['instance'].Value.Trim()
            SourceToken=$sourceToken
            Target=Get-RecommendationTarget $requestedTarget $recommendation
            Recommendation=$recommendation
            ReportLink=if ($htmlReport) { Get-RelativeFileLink $htmlReport.FullName } else { '' }
            LastWriteTimeUtc=$file.LastWriteTimeUtc
        }
    }
}
$recommendations | Export-Csv (Join-Path $SummaryFolder 'sku-recommendations.csv') -NoTypeInformation

$assessmentRecords = foreach ($file in $files | Where-Object Extension -eq '.json') {
    try {
        $report = Get-Content $file.FullName -Raw | ConvertFrom-Json
        $serverValue = Get-PropertyValue $report 'Servers'
        if ($null -eq $serverValue) { continue }
        $servers = @($serverValue | Where-Object {
            $null -ne $_ -and $null -ne (Get-PropertyValue $_ 'TargetReadinesses')
        })
        if ($servers.Count -eq 0) { continue }
        $source = Get-SourceMetadata $file
        $htmlReport = Get-RelatedHtmlReport $file '*SqlAssessment*.html'
        $completedReport = Test-AssessmentCompleted $report
        foreach ($server in $servers) {
            $properties = Get-PropertyValue $server 'Properties'
            $serverName = if ($source -and $source.ServerName) { [string]$source.ServerName } else { [string](Get-PropertyValue $properties 'ServerName') }
            $instanceName = if ($source -and $source.InstanceName) { [string]$source.InstanceName } else { [string](Get-PropertyValue $properties 'InstanceName') }
            $dataSource = if ($source -and $source.DataSource) { [string]$source.DataSource } elseif ($instanceName) { "$serverName\$instanceName" } else { $serverName }
            $displayName = if ($source -and $source.Name) { [string]$source.Name } else { $dataSource }
            $sourceToken = if ($source) { Split-Path $file.DirectoryName -Leaf } else { '' }
            $databases = @(Get-PropertyValue $server 'Databases' | Where-Object { $null -ne $_ })
            $completedVmAssessment = $completedReport -and (Test-AssessmentCompleted $server)
            $vmStatus = Get-ReadinessStatus $server 'AzureSqlVirtualMachine' -CompletedAssessment:$completedVmAssessment
            $vmReadinessSource = if ($null -ne (Get-TargetReadiness $server 'AzureSqlVirtualMachine')) {
                'Explicit JSON target readiness'
            } elseif ($vmStatus -in @('Ready', 'NotReady')) {
                'Completed assessment VM fallback (absent target readiness; database statuses and VM findings checked)'
            } else {
                'No complete VM readiness evidence'
            }
            [pscustomobject]@{
                Identity=Get-NormalizedIdentity $dataSource
                DisplayName=$displayName
                ServerName=$serverName
                InstanceName=$instanceName
                DataSource=$dataSource
                SourceToken=$sourceToken
                SourceSqlEdition=[string](Get-PropertyValue $properties 'ServerEdition')
                SqlDbStatus=Get-ReadinessStatus $server 'AzureSqlDatabase'
                SqlMiStatus=Get-ReadinessStatus $server 'AzureSqlManagedInstance'
                SqlVmStatus=$vmStatus
                SqlVmReadinessSource=$vmReadinessSource
                NumberOfDatabases=$databases.Count
                SqlDbReadyWithWarnings=Get-ReadyWithWarningsCount $server 'AzureSqlDatabase'
                SqlMiReadyWithWarnings=Get-ReadyWithWarningsCount $server 'AzureSqlManagedInstance'
                SqlVmReadyWithWarnings=Get-ReadyWithWarningsCount $server 'AzureSqlVirtualMachine' -CompletedAssessment:$completedVmAssessment
                AssessmentReport=Get-RelativeFileLink $file.FullName
                AssessmentLink=if ($htmlReport) { Get-RelativeFileLink $htmlReport.FullName } else { Get-RelativeFileLink $file.FullName }
                LastWriteTimeUtc=$file.LastWriteTimeUtc
            }
        }
    } catch {
        Write-Warning "Could not parse compatibility summary from $($file.FullName): $($_.Exception.Message)"
    }
}

$instanceSummary = foreach ($assessment in $assessmentRecords |
    Sort-Object LastWriteTimeUtc -Descending |
    Group-Object Identity |
    ForEach-Object { $_.Group | Select-Object -First 1 }) {
    $aliases = @(
        Get-NormalizedIdentity $assessment.DataSource
        Get-NormalizedIdentity $assessment.ServerName
        Get-NormalizedIdentity "$($assessment.ServerName)\$($assessment.InstanceName)"
    ) | Where-Object { $_ } | Select-Object -Unique
    $matchingRecommendations = @($recommendations | Where-Object {
        ($assessment.SourceToken -and $_.SourceToken -eq $assessment.SourceToken) -or
        $aliases -contains (Get-NormalizedIdentity $_.Instance)
    })
    $sqlDbRecommendation = $matchingRecommendations | Where-Object Target -eq 'AzureSqlDatabase' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    $sqlMiRecommendation = $matchingRecommendations | Where-Object Target -eq 'AzureSqlManagedInstance' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    $sqlVmRecommendation = $matchingRecommendations | Where-Object Target -eq 'AzureSqlVirtualMachine' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    [pscustomobject][ordered]@{
        DisplayName=$assessment.DisplayName
        ServerName=$assessment.ServerName
        InstanceName=$assessment.InstanceName
        DataSource=$assessment.DataSource
        NumberOfDatabases=$assessment.NumberOfDatabases
        SourceSqlEdition=$assessment.SourceSqlEdition
        AzureSqlDatabaseCompatibility=$assessment.SqlDbStatus
        AzureSqlDatabaseReadyWithWarnings=$assessment.SqlDbReadyWithWarnings
        AzureSqlDatabaseDetails=if ($assessment.SqlDbStatus -ne 'Not assessed') { $assessment.AssessmentLink } else { '' }
        AzureSqlDatabaseSkuRecommendation=if ($sqlDbRecommendation) { $sqlDbRecommendation.Recommendation } else { '' }
        AzureSqlDatabaseSkuDetails=if ($sqlDbRecommendation) { $sqlDbRecommendation.ReportLink } else { '' }
        AzureSqlManagedInstanceCompatibility=$assessment.SqlMiStatus
        AzureSqlManagedInstanceReadyWithWarnings=$assessment.SqlMiReadyWithWarnings
        AzureSqlManagedInstanceDetails=if ($assessment.SqlMiStatus -ne 'Not assessed') { $assessment.AssessmentLink } else { '' }
        AzureSqlManagedInstanceSkuRecommendation=if ($sqlMiRecommendation) { $sqlMiRecommendation.Recommendation } else { '' }
        AzureSqlManagedInstanceSkuDetails=if ($sqlMiRecommendation) { $sqlMiRecommendation.ReportLink } else { '' }
        AzureSqlIaaSCompatibility=$assessment.SqlVmStatus
        AzureSqlIaaSReadinessSource=$assessment.SqlVmReadinessSource
        AzureSqlIaaSReadyWithWarnings=$assessment.SqlVmReadyWithWarnings
        AzureSqlIaaSDetails=if ($assessment.SqlVmStatus -ne 'Not assessed') { $assessment.AssessmentLink } else { '' }
        AzureSqlIaaSSkuRecommendation=if ($sqlVmRecommendation) { $sqlVmRecommendation.Recommendation } else { '' }
        AzureSqlIaaSSkuDetails=if ($sqlVmRecommendation) { $sqlVmRecommendation.ReportLink } else { '' }
        AssessmentReport=$assessment.AssessmentReport
    }
}
$instanceSummary | Export-Csv (Join-Path $SummaryFolder 'instance-assessment-summary.csv') -NoTypeInformation

$pricingRecommendations = @(
    foreach ($row in $instanceSummary) {
        [pscustomobject]@{ Target='AzureSqlDatabase'; Recommendation=$row.AzureSqlDatabaseSkuRecommendation }
        [pscustomobject]@{ Target='AzureSqlManagedInstance'; Recommendation=$row.AzureSqlManagedInstanceSkuRecommendation }
        [pscustomobject]@{ Target='AzureSqlVirtualMachine'; Recommendation=$row.AzureSqlIaaSSkuRecommendation; SourceSqlEdition=$row.SourceSqlEdition }
    }
)
$pricingSnapshot = New-SummaryPricingSnapshot -Recommendations $pricingRecommendations -Regions $PricingRegion -SkipPricing:$SkipPricing
Export-SummaryPricingCsv -Instances @($instanceSummary) -Snapshot $pricingSnapshot -Regions $PricingRegion -Path (Join-Path $SummaryFolder 'pricing-options.csv')
$pricingJson = ($pricingSnapshot | ConvertTo-Json -Depth 12 -Compress).Replace('<', '\u003c').Replace('>', '\u003e').Replace('&', '\u0026')
$pricingScript = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'summary-pricing.js') -Raw

$assessmentHints = $jsonRows | Where-Object { $_.Path -match '(?i)issue|warning|readiness|recommend|target|severity|category|message' }
$assessmentHints | Export-Csv (Join-Path $SummaryFolder 'assessment-findings-filtered.csv') -NoTypeInformation

function ConvertTo-HtmlText {
    param([string]$Value)
    return [System.Net.WebUtility]::HtmlEncode($Value)
}

function Get-CompatibilityCell {
    param([string]$Status, [string]$DetailsLink, [Parameter(Mandatory)][string]$SectionClass, [string]$StatusNote)
    $normalizedStatus = $Status -replace '[\s_-]', ''
    $displayStatus = switch ($normalizedStatus) {
        'Ready' { 'Ready' }
        'NotReady' { 'Not Ready' }
        'NotAssessed' { 'Not Assessed' }
        default { if ([string]::IsNullOrWhiteSpace($Status)) { 'Unknown' } else { $Status } }
    }
    $statusClass = if ($normalizedStatus -eq 'Ready') { 'ready' } else { 'not-ready' }
    $icon = if ($normalizedStatus -eq 'Ready') { '&#10003;' } else { 'X' }
    $noteAttribute = if ($StatusNote) { " title='$(ConvertTo-HtmlText $StatusNote)'" } else { '' }
    $badge = "<span class='status $statusClass'$noteAttribute><span aria-hidden='true'>$icon</span>$(ConvertTo-HtmlText $displayStatus)</span>"
    if ($normalizedStatus -eq 'NotAssessed' -or [string]::IsNullOrWhiteSpace($DetailsLink)) {
        return "<td class='$SectionClass group-start'>$badge</td>"
    }
    return "<td class='$SectionClass group-start'><a class='status-link' title='View underlying assessment' href='$(ConvertTo-HtmlText $DetailsLink)'>$badge</a></td>"
}

function Get-RecommendationCell {
    param([string]$Recommendation, [string]$DetailsLink, [Parameter(Mandatory)][string]$SectionClass)
    $encodedRecommendation = ConvertTo-HtmlText $Recommendation
    if ([string]::IsNullOrWhiteSpace($Recommendation)) {
        return "<td class='$SectionClass'><span class='muted'>Not available</span></td>"
    }
    if ([string]::IsNullOrWhiteSpace($Recommendation) -or [string]::IsNullOrWhiteSpace($DetailsLink)) {
        return "<td class='$SectionClass'>$encodedRecommendation</td>"
    }
    return "<td class='$SectionClass'><a href='$(ConvertTo-HtmlText $DetailsLink)'>$encodedRecommendation</a></td>"
}

function Get-CostCell {
    param([string]$Target, [string]$Recommendation, [string]$SectionClass, [string]$SourceSqlEdition)
    $key = Get-SummaryPricingKey $Target $Recommendation $SourceSqlEdition
    return "<td class='$SectionClass cost-cell' data-pricing-key='$(ConvertTo-HtmlText $key)'></td>"
}

$instanceRows = foreach ($row in $instanceSummary) {
    @"
<tr>
<td>$(ConvertTo-HtmlText $row.DisplayName)</td>
<td>$(ConvertTo-HtmlText $row.ServerName)</td>
<td>$(ConvertTo-HtmlText $row.InstanceName)</td>
<td>$(ConvertTo-HtmlText $row.NumberOfDatabases)</td>
$(Get-CompatibilityCell $row.AzureSqlDatabaseCompatibility $row.AzureSqlDatabaseDetails 'section-db')
<td class='section-db'>$(ConvertTo-HtmlText $row.AzureSqlDatabaseReadyWithWarnings)</td>
$(Get-RecommendationCell $row.AzureSqlDatabaseSkuRecommendation $row.AzureSqlDatabaseSkuDetails 'section-db')
$(Get-CostCell 'AzureSqlDatabase' $row.AzureSqlDatabaseSkuRecommendation 'section-db')
$(Get-CompatibilityCell $row.AzureSqlManagedInstanceCompatibility $row.AzureSqlManagedInstanceDetails 'section-mi')
<td class='section-mi'>$(ConvertTo-HtmlText $row.AzureSqlManagedInstanceReadyWithWarnings)</td>
$(Get-RecommendationCell $row.AzureSqlManagedInstanceSkuRecommendation $row.AzureSqlManagedInstanceSkuDetails 'section-mi')
$(Get-CostCell 'AzureSqlManagedInstance' $row.AzureSqlManagedInstanceSkuRecommendation 'section-mi')
$(Get-CompatibilityCell $row.AzureSqlIaaSCompatibility $row.AzureSqlIaaSDetails 'section-iaas' -StatusNote $row.AzureSqlIaaSReadinessSource)
<td class='section-iaas'>$(ConvertTo-HtmlText $row.AzureSqlIaaSReadyWithWarnings)</td>
$(Get-RecommendationCell $row.AzureSqlIaaSSkuRecommendation $row.AzureSqlIaaSSkuDetails 'section-iaas')
$(Get-CostCell 'AzureSqlVirtualMachine' $row.AzureSqlIaaSSkuRecommendation 'section-iaas' $row.SourceSqlEdition)
</tr>
"@
}
$instanceTable = if (@($instanceSummary).Count -gt 0) {
    @"
<div class='table-scroll' role='region' aria-label='Instance compatibility and SKU recommendations' tabindex='0'>
<table class='instance-table'>
<thead>
<tr>
<th rowspan='2' scope='col'>Display Name</th><th rowspan='2' scope='col'>Server</th><th rowspan='2' scope='col'>Instance</th><th rowspan='2' scope='col'>Databases</th>
<th colspan='4' scope='colgroup' class='section-db group-start target-heading'>Azure SQL Database</th>
<th colspan='4' scope='colgroup' class='section-mi group-start target-heading'>Azure SQL Managed Instance</th>
<th colspan='4' scope='colgroup' class='section-iaas group-start target-heading'>SQL Server on Azure VM</th>
</tr>
<tr>
<th scope='col' class='section-db group-start'>Compatibility</th><th scope='col' class='section-db'>Warnings</th><th scope='col' class='section-db'>SKU Recommendation</th>
<th scope='col' class='section-db'>Estimated cost/month</th>
<th scope='col' class='section-mi group-start'>Compatibility</th><th scope='col' class='section-mi'>Warnings</th><th scope='col' class='section-mi'>SKU Recommendation</th>
<th scope='col' class='section-mi'>Estimated cost/month</th>
<th scope='col' class='section-iaas group-start'>Compatibility</th><th scope='col' class='section-iaas'>Warnings</th><th scope='col' class='section-iaas'>SKU Recommendation</th>
<th scope='col' class='section-iaas'>Estimated cost/month</th>
</tr>
</thead><tbody>$($instanceRows -join [Environment]::NewLine)</tbody>
</table>
</div>
"@
} else {
    "<p class='note'>No compatibility assessment reports were found under the results root.</p>"
}

$html = @"
<!doctype html><html lang='en'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width, initial-scale=1'><title>Azure SQL Assessment Summary</title>
<script>
  (() => {
    const param = new URLSearchParams(window.location.search).get("scoutTheme");
    const theme =
      param || (window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
    document.documentElement.setAttribute("data-theme", theme);
  })();
</script>
<style>
:root {
  color-scheme: light;
  --cp-bg: #f7f4ef;
  --cp-bg-elevated: #fcfbf8;
  --cp-surface: #ffffff;
  --cp-surface-soft: #f5f5f5;
  --cp-border: #dedede;
  --cp-border-strong: #919191;
  --cp-text: #242424;
  --cp-text-muted: #5c5c5c;
  --cp-text-soft: #6f6f6f;
  --cp-accent: #b11f4b;
  --cp-accent-hover: #9a1a41;
  --cp-accent-soft: rgba(177, 31, 75, 0.08);
  --cp-accent-fg: #ffffff;
  --cp-success: #16a34a;
  --cp-danger: #dc2626;
  --cp-warning: #f59e0b;
  --cp-link: #0078d4;
  --cp-shadow: 0 18px 48px rgba(0, 0, 0, 0.12);
  --cp-overlay: rgba(255, 255, 255, 0.8);
  --cp-panel: rgba(255, 255, 255, 0.86);
  --cp-panel-strong: rgba(255, 255, 255, 0.96);
  --cp-sheen: rgba(255, 255, 255, 0.55);
  --cp-highlight: rgba(177, 31, 75, 0.12);
}
html[data-theme="dark"] {
  color-scheme: dark;
  --cp-bg: #3d3b3a;
  --cp-bg-elevated: #343231;
  --cp-surface: #292929;
  --cp-surface-soft: #2e2e2e;
  --cp-border: #474747;
  --cp-border-strong: #5f5f5f;
  --cp-text: #dedede;
  --cp-text-muted: #919191;
  --cp-text-soft: #b0b0b0;
  --cp-accent: #fd8ea1;
  --cp-accent-hover: #fb7b91;
  --cp-accent-soft: rgba(253, 142, 161, 0.14);
  --cp-accent-fg: #1a1a1a;
  --cp-success: #4ade80;
  --cp-danger: #f87171;
  --cp-warning: #fbbf24;
  --cp-link: #4da6ff;
  --cp-shadow: 0 18px 48px rgba(0, 0, 0, 0.32);
  --cp-overlay: rgba(41, 41, 41, 0.88);
  --cp-panel: rgba(41, 41, 41, 0.72);
  --cp-panel-strong: rgba(41, 41, 41, 0.96);
  --cp-sheen: rgba(255, 255, 255, 0.04);
  --cp-highlight: rgba(253, 142, 161, 0.12);
}
* { box-sizing: border-box; }
body { margin: 0; padding: 32px; background: var(--cp-bg); color: var(--cp-text); font-family: "Segoe UI", Aptos, Calibri, -apple-system, BlinkMacSystemFont, sans-serif; font-size: 14px; line-height: 1.5; }
main { max-width: 1920px; margin: 0 auto; }
header { margin-bottom: 24px; }
.eyebrow { color: var(--cp-accent); font-size: 12px; font-weight: 700; letter-spacing: .12em; text-transform: uppercase; }
h1 { margin: 8px 0; font-size: 32px; font-weight: 650; letter-spacing: -.025em; }
h2 { margin: 0 0 8px; font-size: 20px; font-weight: 600; }
p { margin: 8px 0 16px; }
.muted, .section-description { color: var(--cp-text-muted); }
.card { margin: 24px 0; padding: 24px; border: 1px solid var(--cp-border); border-radius: 16px; background: var(--cp-surface); }
.table-scroll { overflow-x: auto; border: 1px solid var(--cp-border); border-radius: .625rem; }
table { border-collapse: separate; border-spacing: 0; width: 100%; font-size: 13px; }
.instance-table { min-width: 2040px; }
.instance-table th { overflow-wrap: normal; white-space: nowrap; }
th, td { padding: 16px; text-align: left; vertical-align: top; border-bottom: 1px solid var(--cp-border); overflow-wrap: anywhere; }
th { background: var(--cp-surface-soft); color: var(--cp-text-muted); font-weight: 600; }
thead tr:first-child th { vertical-align: middle; }
tbody tr:last-child td { border-bottom: 0; }
.instance-table td:first-child { font-weight: 600; }
.section-db { background: var(--cp-accent-soft); }
.section-mi { background: var(--cp-bg-elevated); }
.section-iaas { background: var(--cp-surface-soft); }
.group-start { border-left: 3px solid var(--cp-border-strong); }
th.target-heading { color: var(--cp-text); font-size: 14px; padding-top: 20px; padding-bottom: 20px; }
th.section-db.target-heading { color: var(--cp-accent); }
.status { display: inline-flex; align-items: center; gap: 8px; white-space: nowrap; font-weight: 650; }
.ready { color: var(--cp-success); }
.not-ready { color: var(--cp-danger); }
a { color: var(--cp-link); text-underline-offset: 3px; }
a:hover { text-decoration-thickness: 2px; }
.status-link { color: inherit; }
.status-link .status { text-decoration: underline; text-underline-offset: 3px; }
.pricing-controls { display: flex; flex-wrap: wrap; gap: 16px 24px; margin: 16px 0; align-items: end; }
.pricing-field { display: flex; flex-direction: column; gap: 8px; font-weight: 600; }
.pricing-check { display: flex; gap: 8px; align-items: center; }
.pricing-controls select { padding: 8px 12px; border: 1px solid var(--cp-border-strong); border-radius: .625rem; background: var(--cp-surface); color: var(--cp-text); font: inherit; max-width: 100%; }
.pricing-controls input { accent-color: var(--cp-accent); }
.pricing-controls [hidden] { display: none; }
.cost-value { font-weight: 650; white-space: nowrap; }
.cost-scope { display: block; color: var(--cp-text-muted); margin-top: 4px; }
.cost-unavailable { color: var(--cp-danger); }
.cost-cell details { margin-top: 8px; min-width: 156px; font-size: 12px; color: var(--cp-text-muted); }
.cost-cell summary { cursor: pointer; color: var(--cp-link); }
.cost-cell ul { padding-left: 16px; }
.cost-cell li { margin-bottom: 8px; }
a:focus-visible, .table-scroll:focus-visible { outline: 2px solid var(--cp-accent); outline-offset: 2px; }
.note { padding: 16px 20px; border: 1px solid var(--cp-border); border-left: 4px solid var(--cp-warning); border-radius: .625rem; background: var(--cp-bg-elevated); color: var(--cp-text-muted); }
@media (max-width: 768px) { body { padding: 16px; } .card { padding: 16px; } h1 { font-size: 26px; } }
@media print { body { padding: 0; } .card { padding: 12px; } .table-scroll { overflow: visible; } .instance-table { min-width: 0; } th, td { padding: 4px; font-size: 10px; } }
</style></head><body><main>
<header>
<div class='eyebrow'>Migration readiness report</div>
<h1>Azure SQL Migration Assessment Summary</h1>
<p class='muted'>Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz') &middot; $(@($instanceSummary).Count) source instances</p>
</header>
<div class='note'>Validate compatibility findings before accepting a SKU. Performance sizing does not resolve feature blockers, cross-database dependencies, latency requirements, or operational constraints.</div>
<section class='card' aria-labelledby='pricing-heading'>
<h2 id='pricing-heading'>Cost estimate settings</h2>
<p class='section-description'>Offline retail estimates for each displayed recommended resource, not a total for all databases. Choose a region to populate costs; PAYG applies unless a commitment option is selected. Discounts apply only to eligible compute, not SQL licensing or storage.</p>
<div class='pricing-controls'>
<label class='pricing-field'>Azure region<select id='pricing-region'><option value=''>Select a region</option></select></label>
<label class='pricing-field'>Pricing option<select id='pricing-plan'><option value='payg'>Pay as you go</option><option value='ri1'>1-year reserved instance</option><option value='ri3'>3-year reserved instance</option><option value='dbsp1'>1-year database savings plan</option></select></label>
<label class='pricing-check'><input type='checkbox' id='pricing-ahb'>Use Azure Hybrid Benefit for eligible SQL licenses</label>
<label class='pricing-check' id='pricing-gen5-field'><input type='checkbox' id='pricing-gen5'>Use Standard-series (Gen5) when SQL hardware is unspecified</label>
</div>
<p class='muted' id='pricing-status' role='status' aria-live='polite'></p>
<p class='muted'>VM SQL licensing uses the edition specified in the SKU recommendation, or the assessed source server's SQL edition when unspecified. Missing or unsupported editions remain unavailable rather than being assumed.</p>
<p class='muted'>VM operating system defaults to Windows Server when unspecified, including Windows Server licensing. Explicit Linux recommendations retain Linux pricing.</p>
<p class='muted'><a href='pricing-options.csv'>Pricing options CSV for Ready targets</a>: generated for the command-line pricing regions (or available snapshot regions). Browser selections do not change this file.</p>
</section>
<section class='card'>
<h2>Instance compatibility and SKU recommendations</h2>
<p class='section-description'>Compare migration targets side by side. Select Ready or Not Ready to view the underlying assessment (HTML when available, otherwise JSON), or select a SKU recommendation to open its available report.</p>
$instanceTable
<p class='muted'>Warnings counts databases that are Ready for the target but have one or more warning findings. A zero does not mean the target is assessed or free of compatibility blockers. Not Assessed has no assessment link.</p>
<p class='muted'>VM readiness can be inferred from a completed, error-free assessment when JSON omits VM readiness, matching the native report's VM default. Explicit statuses and blockers are respected. Hover over the VM status for its source; the instance CSV records AzureSqlIaaSReadinessSource.</p>
</section>
<script type='application/json' id='pricing-data'>$pricingJson</script>
<script>$pricingScript</script>
</main></body></html>
"@
$html | Set-Content (Join-Path $SummaryFolder 'assessment-summary.html') -Encoding UTF8
Write-Host "Summary written to $SummaryFolder"
Write-Host 'Open assessment-summary.html and review the CSV files for detailed filtering.'
