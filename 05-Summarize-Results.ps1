[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResultsRoot,
    [string]$SummaryFolder = (Join-Path $PSScriptRoot 'summary')
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $ResultsRoot)) { throw "Results folder not found: $ResultsRoot" }
$ResultsRoot = (Resolve-Path $ResultsRoot).Path
New-Item -ItemType Directory -Path $SummaryFolder -Force | Out-Null

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

function Get-ReadinessStatus {
    param($Server, [Parameter(Mandatory)][string]$Target)
    $targetReadinesses = Get-PropertyValue $Server 'TargetReadinesses'
    $readiness = Get-PropertyValue $targetReadinesses $Target
    if (-not $readiness) { return 'Not assessed' }
    $status = [string](Get-PropertyValue $readiness 'RecommendationStatus')
    if ([string]::IsNullOrWhiteSpace($status)) { return 'Unknown' }
    return $status
}

function Get-FileLink {
    param([Parameter(Mandatory)][string]$Path)
    return ([System.Uri]::new((Resolve-Path $Path).Path)).AbsoluteUri
}

function Get-RelatedHtmlReport {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$SourceFile,
        [Parameter(Mandatory)][string]$NamePattern
    )
    $htmlFiles = @(Get-ChildItem $SourceFile.DirectoryName -File -Filter $NamePattern -ErrorAction SilentlyContinue)
    $matchingBaseName = $htmlFiles | Where-Object BaseName -eq $SourceFile.BaseName | Select-Object -First 1
    $htmlFile = if ($matchingBaseName) {
        $matchingBaseName
    } else {
        $htmlFiles | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
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
            ReportLink=if ($htmlReport) { Get-FileLink $htmlReport.FullName } else { '' }
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
        foreach ($server in $servers) {
            $properties = Get-PropertyValue $server 'Properties'
            $serverName = if ($source -and $source.ServerName) { [string]$source.ServerName } else { [string](Get-PropertyValue $properties 'ServerName') }
            $instanceName = if ($source -and $source.InstanceName) { [string]$source.InstanceName } else { [string](Get-PropertyValue $properties 'InstanceName') }
            $dataSource = if ($source -and $source.DataSource) { [string]$source.DataSource } elseif ($instanceName) { "$serverName\$instanceName" } else { $serverName }
            $displayName = if ($source -and $source.Name) { [string]$source.Name } else { $dataSource }
            $sourceToken = if ($source) { Split-Path $file.DirectoryName -Leaf } else { '' }
            [pscustomobject]@{
                Identity=Get-NormalizedIdentity $dataSource
                DisplayName=$displayName
                ServerName=$serverName
                InstanceName=$instanceName
                DataSource=$dataSource
                SourceToken=$sourceToken
                SqlDbStatus=Get-ReadinessStatus $server 'AzureSqlDatabase'
                SqlMiStatus=Get-ReadinessStatus $server 'AzureSqlManagedInstance'
                SqlVmStatus=Get-ReadinessStatus $server 'AzureSqlVirtualMachine'
                AssessmentReport=$file.FullName
                AssessmentLink=if ($htmlReport) { Get-FileLink $htmlReport.FullName } else { '' }
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
        AzureSqlDatabaseCompatibility=$assessment.SqlDbStatus
        AzureSqlDatabaseDetails=$assessment.AssessmentLink
        AzureSqlDatabaseSkuRecommendation=if ($sqlDbRecommendation) { $sqlDbRecommendation.Recommendation } else { '' }
        AzureSqlDatabaseSkuDetails=if ($sqlDbRecommendation) { $sqlDbRecommendation.ReportLink } else { '' }
        AzureSqlManagedInstanceCompatibility=$assessment.SqlMiStatus
        AzureSqlManagedInstanceDetails=$assessment.AssessmentLink
        AzureSqlManagedInstanceSkuRecommendation=if ($sqlMiRecommendation) { $sqlMiRecommendation.Recommendation } else { '' }
        AzureSqlManagedInstanceSkuDetails=if ($sqlMiRecommendation) { $sqlMiRecommendation.ReportLink } else { '' }
        AzureSqlIaaSCompatibility=$assessment.SqlVmStatus
        AzureSqlIaaSDetails=$assessment.AssessmentLink
        AzureSqlIaaSSkuRecommendation=if ($sqlVmRecommendation) { $sqlVmRecommendation.Recommendation } else { '' }
        AzureSqlIaaSSkuDetails=if ($sqlVmRecommendation) { $sqlVmRecommendation.ReportLink } else { '' }
        AssessmentReport=$assessment.AssessmentReport
    }
}
$instanceSummary | Export-Csv (Join-Path $SummaryFolder 'instance-assessment-summary.csv') -NoTypeInformation

$assessmentHints = $jsonRows | Where-Object { $_.Path -match '(?i)issue|warning|readiness|recommend|target|severity|category|message' }
$assessmentHints | Export-Csv (Join-Path $SummaryFolder 'assessment-findings-filtered.csv') -NoTypeInformation

function ConvertTo-HtmlText {
    param([string]$Value)
    return [System.Net.WebUtility]::HtmlEncode($Value)
}

function Get-CompatibilityCell {
    param([string]$Status, [string]$DetailsLink)
    $encodedStatus = ConvertTo-HtmlText $Status
    $className = if ($Status -eq 'Ready') { 'ready' } else { 'review' }
    if ([string]::IsNullOrWhiteSpace($DetailsLink)) { return "<td class='$className'>$encodedStatus</td>" }
    return "<td class='$className'><a href='$(ConvertTo-HtmlText $DetailsLink)'>$encodedStatus</a></td>"
}

function Get-RecommendationCell {
    param([string]$Recommendation, [string]$DetailsLink)
    $encodedRecommendation = ConvertTo-HtmlText $Recommendation
    if ([string]::IsNullOrWhiteSpace($Recommendation) -or [string]::IsNullOrWhiteSpace($DetailsLink)) {
        return "<td>$encodedRecommendation</td>"
    }
    return "<td><a href='$(ConvertTo-HtmlText $DetailsLink)'>$encodedRecommendation</a></td>"
}

$instanceRows = foreach ($row in $instanceSummary) {
    @"
<tr>
<td>$(ConvertTo-HtmlText $row.DisplayName)</td>
<td>$(ConvertTo-HtmlText $row.ServerName)</td>
<td>$(ConvertTo-HtmlText $row.InstanceName)</td>
$(Get-CompatibilityCell $row.AzureSqlDatabaseCompatibility $row.AzureSqlDatabaseDetails)
$(Get-RecommendationCell $row.AzureSqlDatabaseSkuRecommendation $row.AzureSqlDatabaseSkuDetails)
$(Get-CompatibilityCell $row.AzureSqlManagedInstanceCompatibility $row.AzureSqlManagedInstanceDetails)
$(Get-RecommendationCell $row.AzureSqlManagedInstanceSkuRecommendation $row.AzureSqlManagedInstanceSkuDetails)
$(Get-CompatibilityCell $row.AzureSqlIaaSCompatibility $row.AzureSqlIaaSDetails)
$(Get-RecommendationCell $row.AzureSqlIaaSSkuRecommendation $row.AzureSqlIaaSSkuDetails)
</tr>
"@
}
$instanceTable = if (@($instanceSummary).Count -gt 0) {
    "<table><thead><tr><th>Display name</th><th>Server</th><th>Instance</th><th>SQL Database compatibility</th><th>SQL Database SKU</th><th>Managed Instance compatibility</th><th>Managed Instance SKU</th><th>Azure SQL IaaS compatibility</th><th>Azure SQL IaaS SKU</th></tr></thead><tbody>$($instanceRows -join [Environment]::NewLine)</tbody></table>"
} else {
    "<p class='note'>No compatibility assessment reports were found under the results root.</p>"
}

$html = @"
<!doctype html><html><head><meta charset='utf-8'><title>Azure SQL Assessment Summary</title>
<style>body{font-family:Segoe UI,Arial;margin:32px;color:#242424}h1,h2{color:#0f6cbd}table{border-collapse:collapse;width:100%;margin-bottom:24px}th,td{border:1px solid #ddd;padding:8px;text-align:left;vertical-align:top}th{background:#eaf3fb}.note{background:#fff4ce;padding:12px;border-left:4px solid #f1c21b}.ready{background:#dff6dd}.review{background:#fff4ce}.review a{font-weight:600;color:#8a3707}</style></head><body>
<h1>Azure SQL Migration Assessment Summary</h1>
<p>Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')</p>
<div class='note'>Validate compatibility findings before accepting a SKU. Performance sizing does not resolve feature blockers, cross-database dependencies, latency requirements, or operational constraints.</div>
<h2>Instance compatibility and SKU recommendations</h2>
$instanceTable
<h2>SKU recommendations</h2>
$($recommendations | ConvertTo-Html -Fragment)
<h2>Output inventory</h2>
$($catalog | ConvertTo-Html -Fragment)
</body></html>
"@
$html | Set-Content (Join-Path $SummaryFolder 'assessment-summary.html')
Write-Host "Summary written to $SummaryFolder"
Write-Host 'Open assessment-summary.html and review the CSV files for detailed filtering.'
