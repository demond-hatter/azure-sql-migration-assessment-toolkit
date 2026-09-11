[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResultsRoot,
    [string]$SummaryFolder = (Join-Path $PSScriptRoot 'summary')
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $ResultsRoot)) { throw "Results folder not found: $ResultsRoot" }
New-Item -ItemType Directory -Path $SummaryFolder -Force | Out-Null

$files = Get-ChildItem $ResultsRoot -Recurse -File
$catalog = $files | Select-Object @{n='RelativePath';e={$_.FullName.Substring((Resolve-Path $ResultsRoot).Path.Length).TrimStart('\','/')}},Extension,Length,LastWriteTimeUtc
$catalog | Export-Csv (Join-Path $SummaryFolder 'file-catalog.csv') -NoTypeInformation

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
        [pscustomobject]@{
            SourceFile=$file.Name
            Instance=$match.Groups['instance'].Value.Trim()
            Recommendation=($match.Groups['recommendation'].Value -replace '\s+',' ').Trim()
        }
    }
}
$recommendations | Export-Csv (Join-Path $SummaryFolder 'sku-recommendations.csv') -NoTypeInformation

$assessmentHints = $jsonRows | Where-Object { $_.Path -match '(?i)issue|warning|readiness|recommend|target|severity|category|message' }
$assessmentHints | Export-Csv (Join-Path $SummaryFolder 'assessment-findings-filtered.csv') -NoTypeInformation

$html = @"
<!doctype html><html><head><meta charset='utf-8'><title>Azure SQL Assessment Summary</title>
<style>body{font-family:Segoe UI,Arial;margin:32px;color:#242424}h1,h2{color:#0f6cbd}table{border-collapse:collapse;width:100%;margin-bottom:24px}th,td{border:1px solid #ddd;padding:8px;text-align:left;vertical-align:top}th{background:#eaf3fb}.note{background:#fff4ce;padding:12px;border-left:4px solid #f1c21b}</style></head><body>
<h1>Azure SQL Migration Assessment Summary</h1>
<p>Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')</p>
<div class='note'>Validate compatibility findings before accepting a SKU. Performance sizing does not resolve feature blockers, cross-database dependencies, latency requirements, or operational constraints.</div>
<h2>SKU recommendations</h2>
$($recommendations | ConvertTo-Html -Fragment)
<h2>Output inventory</h2>
$($catalog | ConvertTo-Html -Fragment)
</body></html>
"@
$html | Set-Content (Join-Path $SummaryFolder 'assessment-summary.html')
Write-Host "Summary written to $SummaryFolder"
Write-Host 'Open assessment-summary.html and review the CSV files for detailed filtering.'
