[CmdletBinding()]
param([switch]$KeepArtifacts)

$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sql-summary-tests-" + [guid]::NewGuid())
$results = Join-Path $testRoot 'results & #1'
$summary = Join-Path $testRoot 'summary & #1'
$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) '05-Summarize-Results.ps1'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function New-Readiness {
    param([string]$Status)
    return @{ RecommendationStatus = $Status }
}

function Write-Assessment {
    param([string]$Folder, [string]$ServerName, [hashtable]$Readiness, [array]$Databases = @())
    New-Item -ItemType Directory -Path $Folder -Force | Out-Null
    @{
        Servers = @(@{
            Properties = @{ ServerName = $ServerName; InstanceName = '' }
            TargetReadinesses = $Readiness
            Databases = $Databases
        })
    } | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $Folder 'SqlAssessment.json') -Encoding UTF8
}

try {
    $primary = Join-Path $results 'primary'
    $targets = @('AzureSqlDatabase', 'AzureSqlManagedInstance', 'AzureSqlVirtualMachine')
    $databaseReadiness = @{}
    foreach ($target in $targets) { $databaseReadiness[$target] = New-Readiness 'Ready' }
    $warnings = foreach ($target in $targets) {
        @{ IssueCategory = 'Warning'; AppliesToMigrationTargetPlatform = $target }
        @{ IssueCategory = 'Warning'; AppliesToMigrationTargetPlatform = $target }
    }
    $databases = @(
        @{ TargetReadinesses = $databaseReadiness; DatabaseAssessments = @($warnings) }
        @{ TargetReadinesses = $databaseReadiness; DatabaseAssessments = @() }
        @{
            TargetReadinesses = @{ AzureSqlVirtualMachine = (New-Readiness 'NotReady') }
            DatabaseAssessments = @(@{ IssueCategory = 'Warning'; AppliesToMigrationTargetPlatform = 'AzureSqlVirtualMachine' })
        }
    )
    Write-Assessment $primary 'demo-sql' @{
        AzureSqlDatabase = (New-Readiness 'Ready')
        AzureSqlManagedInstance = (New-Readiness 'NotReady')
    } $databases
    [pscustomobject]@{
        Name = 'Finance & <Primary>'
        ServerName = 'demo-sql'
        InstanceName = 'ERP'
        DataSource = 'demo-sql\ERP'
    } | Export-Csv (Join-Path $primary 'demo-source.csv') -NoTypeInformation
    Rename-Item (Join-Path $primary 'SqlAssessment.json') -NewName 'demo-assessment.json'
    '<!doctype html><title>Assessment fixture</title>' |
        Set-Content (Join-Path $primary 'demo-assessment.html')

    $skuNames = @('Azure SQL Database General Purpose <4> & storage', 'Azure SQL Managed Instance General Purpose 8', 'SQL Server on Azure VM Standard_D8s_v5')
    for ($i = 0; $i -lt $targets.Count; $i++) {
        $skuFolder = Join-Path $results (Join-Path 'recommendations' (Join-Path 'primary' $targets[$i]))
        New-Item -ItemType Directory -Path $skuFolder -Force | Out-Null
        "Instance name: demo-sql\ERP`r`nSKU recommendation: $($skuNames[$i])`r`nRecommendation reasons: Test fixture" |
            Set-Content (Join-Path $skuFolder 'demo-console.txt')
        '<!doctype html><title>SKU fixture</title>' |
            Set-Content (Join-Path $skuFolder 'SkuRecommendationReport.html')
    }

    Write-Assessment (Join-Path $results 'without-html') 'demo-no-links' @{
        AzureSqlDatabase = (New-Readiness 'Ready')
        AzureSqlManagedInstance = (New-Readiness 'Not Ready')
        AzureSqlVirtualMachine = (New-Readiness '')
    }
    $notAssessed = Join-Path $results 'not-assessed'
    Write-Assessment $notAssessed 'demo-not-assessed' @{
        AzureSqlDatabase = (New-Readiness 'NotAssessed')
        AzureSqlManagedInstance = (New-Readiness 'Not Assessed')
        AzureSqlVirtualMachine = (New-Readiness 'not_assessed')
    }
    '<!doctype html><title>Unused assessment fixture</title>' |
        Set-Content (Join-Path $notAssessed 'SqlAssessment.html')

    & $scriptPath -ResultsRoot $results -SummaryFolder $summary -SkipPricing
    $html = Get-Content (Join-Path $summary 'assessment-summary.html') -Raw -Encoding UTF8
    $tableMarkup = [regex]::Match($html, "(?s)<table class='instance-table'>.*?</table>").Value
    Assert-True (-not [string]::IsNullOrWhiteSpace($tableMarkup)) 'Instance table is generated'
    [xml]$table = $tableMarkup
    $headerRows = @($table.table.thead.tr)
    Assert-True ($headerRows.Count -eq 2) 'Two-tier column headers'
    $identityHeaders = @($headerRows[0].th | Where-Object rowspan -eq '2')
    Assert-True (($identityHeaders.InnerText -join '|') -eq 'Display Name|Server|Instance|Databases') 'Original identity columns preserved'
    $groupHeaders = @($headerRows[0].th | Where-Object colspan -eq '4')
    Assert-True (($groupHeaders.InnerText -join '|') -eq 'Azure SQL Database|Azure SQL Managed Instance|SQL Server on Azure VM') 'Three named target groups'
    Assert-True (@($groupHeaders | Where-Object { $_.scope -eq 'colgroup' -and $_.class -match 'group-start' }).Count -eq 3) 'Accessible, separated groups'
    Assert-True (($headerRows[1].th.InnerText -join '|') -eq ((1..3 | ForEach-Object { 'Compatibility|Warnings|SKU Recommendation|Estimated cost/month' }) -join '|')) 'Identical target subcolumns'

    $rows = @($table.table.tbody.tr)
    Assert-True ($rows.Count -eq 3) 'One row per source instance'
    foreach ($row in $rows) {
        Assert-True (@($row.td).Count -eq 16) 'Every row has 16 columns'
        foreach ($column in @(4, 8, 12)) {
            Assert-True ($row.td[$column].class -match 'group-start') 'Group boundaries align with headers'
        }
        foreach ($column in @(7, 11, 15)) {
            Assert-True ($row.td[$column].InnerText -eq '' -and $row.td[$column].HasAttribute('data-pricing-key')) 'Monthly cost starts blank with a pricing key'
        }
    }
    $primaryRow = $rows | Where-Object { $_.SelectSingleNode('td[1]').InnerText -eq 'Finance & <Primary>' }
    Assert-True ($null -ne $primaryRow) 'HTML-sensitive display name survives encoding'
    $primaryCells = $primaryRow.SelectNodes('td')
    Assert-True ($primaryCells[1].InnerText -eq 'demo-sql' -and $primaryCells[2].InnerText -eq 'ERP' -and $primaryCells[3].InnerText -eq '3') 'Identity and database values preserved'
    Assert-True ($primaryCells[4].a.span.class -eq 'status ready' -and $primaryCells[4].a.span.span.InnerText -eq [string][char]0x2713) 'Ready has a check mark and success styling'
    Assert-True ($primaryCells[8].a.span.class -eq 'status not-ready' -and $primaryCells[8].a.span.InnerText -eq 'XNot Ready') 'NotReady is normalized, red, and marked X'
    foreach ($column in @(4, 8)) {
        Assert-True ($primaryCells[$column].a.href -like '*demo-assessment.html') 'Ready and Not Ready link to the matching HTML assessment regardless of filename pattern'
    }
    Assert-True ($primaryCells[12].span.InnerText -eq 'XNot Assessed' -and $null -eq $primaryCells[12].a) 'Missing target is red with X and no link'
    foreach ($column in @(5, 9, 13)) {
        Assert-True ($primaryCells[$column].InnerText -eq '1') 'Warnings count ready databases, not individual findings or blocked databases'
    }
    for ($i = 0; $i -lt $targets.Count; $i++) {
        $cell = $primaryCells[6 + 4 * $i]
        Assert-True ($cell.a.InnerText -eq $skuNames[$i]) 'Correct SKU in each group with safe HTML encoding'
    }
    $allUnassessed = $rows | Where-Object { $_.SelectSingleNode('td[1]').InnerText -eq 'demo-not-assessed' }
    foreach ($column in @(4, 8, 12)) {
        Assert-True ($allUnassessed.td[$column].span.InnerText -eq 'XNot Assessed' -and $null -eq $allUnassessed.td[$column].a) 'Explicit Not Assessed variants never link'
    }
    $noLinks = $rows | Where-Object { $_.SelectSingleNode('td[1]').InnerText -eq 'demo-no-links' }
    foreach ($column in @(4, 8, 12)) {
        Assert-True ($noLinks.td[$column].a.href -like '*without-html/SqlAssessment.json') 'JSON-only assessments still provide underlying assessment links'
    }
    Assert-True ($noLinks.td[4].a.span.class -eq 'status ready') 'JSON-linked Ready is still green'
    Assert-True ($noLinks.td[8].a.span.InnerText -eq 'XNot Ready') 'Spaced Not Ready is normalized'
    Assert-True ($noLinks.td[12].a.span.InnerText -eq 'XUnknown') 'Unknown is not presented as Ready'
    Assert-True ($noLinks.td[6].InnerText -eq 'Not available') 'Missing SKU is explicit'
    foreach ($link in $table.SelectNodes('//a')) {
        Assert-True ($link.href -notmatch '^(?:[\\/]|[A-Za-z][A-Za-z0-9+.-]*:)') 'All assessment and SKU links are relative, not rooted paths or absolute URIs'
        $relativePath = [System.Uri]::UnescapeDataString($link.href) -replace '/', '\'
        Assert-True (Test-Path -LiteralPath (Join-Path $summary $relativePath)) 'Report links resolve to existing local files, including spaces and URL-special characters'
    }
    Assert-True ($html -match '\.ready\s*\{\s*color: var\(--cp-success\)' -and $html -match '\.not-ready\s*\{\s*color: var\(--cp-danger\)') 'Status colors use green/red theme tokens'
    Assert-True ($html -match 'prefers-color-scheme: dark' -and $html -match 'overflow-x: auto') 'Automatic theme and horizontal scrolling'
    Assert-True ([regex]::Matches($html, '<table\b').Count -eq 1) 'HTML contains only the instance summary table'
    Assert-True ($html -notmatch '<h2>SKU recommendations</h2>|<h2>Output inventory</h2>') 'Standalone SKU and inventory sections are omitted'

    $csv = @(Import-Csv (Join-Path $summary 'instance-assessment-summary.csv'))
    $primaryCsv = $csv | Where-Object DisplayName -eq 'Finance & <Primary>'
    Assert-True ($primaryCsv.AzureSqlIaaSReadyWithWarnings -eq '1') 'VM warnings exported'
    Assert-True ($primaryCsv.AzureSqlDatabaseReadyWithWarnings -eq '1' -and $primaryCsv.AzureSqlManagedInstanceReadyWithWarnings -eq '1') 'Existing warning exports preserved'
    Assert-True ($primaryCsv.AssessmentReport -notmatch '^(?:[\\/]|[A-Za-z][A-Za-z0-9+.-]*:)' -and $primaryCsv.AssessmentReport -like '*demo-assessment.json') 'CSV assessment source path is relative'
    $unassessedCsv = $csv | Where-Object ServerName -eq 'demo-not-assessed'
    Assert-True (-not $unassessedCsv.AzureSqlDatabaseDetails -and -not $unassessedCsv.AzureSqlManagedInstanceDetails -and -not $unassessedCsv.AzureSqlIaaSDetails) 'CSV does not link unassessed targets'
    foreach ($name in @('file-catalog.csv', 'json-details.csv', 'assessment-findings-filtered.csv', 'sku-recommendations.csv')) {
        Assert-True (Test-Path (Join-Path $summary $name)) "Existing export retained: $name"
    }

    $relocatedRoot = Join-Path $testRoot 'relocated bundle'
    New-Item -ItemType Directory -Path $relocatedRoot | Out-Null
    Move-Item -LiteralPath $results -Destination $relocatedRoot
    Move-Item -LiteralPath $summary -Destination $relocatedRoot
    Assert-True (-not (Test-Path -LiteralPath $results) -and -not (Test-Path -LiteralPath $summary)) 'Original report folders no longer exist'
    $relocatedSummary = Join-Path $relocatedRoot (Split-Path $summary -Leaf)
    $relocatedHtml = Get-Content -LiteralPath (Join-Path $relocatedSummary 'assessment-summary.html') -Raw -Encoding UTF8
    Assert-True ($relocatedHtml -eq $html) 'Relocation requires no changes to the generated HTML'
    $summaryFileUri = [System.Uri]::new($relocatedSummary + [System.IO.Path]::DirectorySeparatorChar)
    $summaryUri = [System.Uri]::new($summaryFileUri.AbsoluteUri)
    foreach ($link in $table.SelectNodes('//a')) {
        $targetUri = [System.Uri]::new($summaryUri, $link.href)
        Assert-True (Test-Path -LiteralPath $targetUri.LocalPath) "Relocated link '$($link.href)' resolves to an existing file: $($targetUri.LocalPath)"
    }
    $sourceUri = [System.Uri]::new($summaryUri, $primaryCsv.AssessmentReport)
    Assert-True (Test-Path -LiteralPath $sourceUri.LocalPath) 'CSV source report path still resolves after relocation'
    foreach ($record in $csv) {
        foreach ($property in $record.PSObject.Properties | Where-Object { $_.Name -match 'Details$|^AssessmentReport$' -and $_.Value }) {
            Assert-True ($property.Value -notmatch '^(?:[\\/]|[A-Za-z][A-Za-z0-9+.-]*:)') "CSV $($property.Name) is relative"
            $targetUri = [System.Uri]::new($summaryUri, $property.Value)
            Assert-True (Test-Path -LiteralPath $targetUri.LocalPath) "CSV $($property.Name) resolves after relocation"
        }
    }

    $vmResults = Join-Path $testRoot 'vm-results'
    $vmSummary = Join-Path $testRoot 'vm-summary'
    $vmCases = @(
        @{ name='clean'; expected='Ready'; warnings=0 }
        @{ name='warning-only'; expected='Ready'; warnings=1 }
        @{ name='native-alias'; expected='Ready'; warnings=1 }
        @{ name='iaas-alias'; expected='NotReady'; warnings=0 }
        @{ name='explicit-not-ready'; expected='NotReady'; warnings=0 }
        @{ name='explicit-not-assessed'; expected='Not assessed'; warnings=0 }
        @{ name='explicit-unknown'; expected='Unknown'; warnings=0 }
        @{ name='server-warning'; expected='Ready'; warnings=0 }
        @{ name='database-issue'; expected='NotReady'; warnings=0 }
        @{ name='database-blocking-issue'; expected='NotReady'; warnings=0 }
        @{ name='database-critical'; expected='NotReady'; warnings=0 }
        @{ name='server-blocker'; expected='NotReady'; warnings=0 }
        @{ name='database-not-ready'; expected='NotReady'; warnings=0 }
        @{ name='database-not-assessed'; expected='Not assessed'; warnings=0 }
        @{ name='report-failed'; expected='Not assessed'; warnings=0 }
        @{ name='server-failed'; expected='Not assessed'; warnings=0 }
        @{ name='database-failed'; expected='Not assessed'; warnings=0 }
        @{ name='database-failed-with-ready'; expected='Not assessed'; warnings=0 }
        @{ name='report-errors'; expected='Not assessed'; warnings=0 }
        @{ name='server-errors'; expected='Not assessed'; warnings=0 }
        @{ name='database-errors'; expected='Not assessed'; warnings=0 }
        @{ name='missing-status'; expected='Not assessed'; warnings=0 }
        @{ name='empty-databases'; expected='Not assessed'; warnings=0 }
    )
    foreach ($case in $vmCases) {
        $folder = Join-Path $vmResults $case.name
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        $database = @{
            Status='Completed'; Errors=@(); DatabaseAssessments=@()
            TargetReadinesses=@{ AzureSqlDatabase=(New-Readiness 'Ready') }
        }
        $server = @{
            Status='Completed'; Errors=@(); ServerAssessments=@()
            Properties=@{ServerName=$case.name; InstanceName='ERP'}
            TargetReadinesses=@{AzureSqlDatabase=(New-Readiness 'NotReady'); AzureSqlManagedInstance=(New-Readiness 'NotReady')}
            Databases=@($database)
        }
        $report = @{Status='Completed'; Errors=@(); Servers=@($server)}
        $warning = @{IssueCategory='Warning'; AppliesToMigrationTargetPlatform='SqlServerOnAzureVM'}
        switch ($case.name) {
            'clean' { $database.DatabaseAssessments=@(@{IssueCategory='Issue'; AppliesToMigrationTargetPlatform='AzureSqlDatabase'}) }
            'warning-only' { $database.DatabaseAssessments=@($warning, $warning) }
            'native-alias' {
                $server.TargetReadinesses.SqlServerOnAzureVM = New-Readiness 'Ready'
                $database.TargetReadinesses.SqlServerOnAzureVM = New-Readiness 'Ready'
                $database.DatabaseAssessments=@($warning, $warning)
            }
            'iaas-alias' { $server.TargetReadinesses.AzureSqlIaaS = New-Readiness 'NotReady' }
            'explicit-not-ready' { $server.TargetReadinesses.AzureSqlVirtualMachine = New-Readiness 'NotReady' }
            'explicit-not-assessed' { $server.TargetReadinesses.SqlServerOnAzureVM = New-Readiness 'NotAssessed' }
            'explicit-unknown' { $server.TargetReadinesses.SqlServerOnAzureVM = New-Readiness '' }
            'server-warning' { $server.ServerAssessments=@($warning) }
            'database-issue' { $database.DatabaseAssessments=@(@{IssueCategory='Issue'; AppliesToMigrationTargetPlatform='SqlServerOnAzureVM'}) }
            'database-blocking-issue' { $database.DatabaseAssessments=@(@{IssueCategory='BlockingIssue'; AppliesToMigrationTargetPlatform='AzureSqlIaaS'}) }
            'database-critical' { $database.DatabaseAssessments=@(@{IssueCategory='Critical'; AppliesToMigrationTargetPlatform='AzureSqlVirtualMachine'}) }
            'server-blocker' { $server.ServerAssessments=@(@{IssueCategory='Issue'; AppliesToMigrationTargetPlatform='SqlServerOnAzureVM'}) }
            'database-not-ready' { $database.TargetReadinesses.SqlServerOnAzureVM = New-Readiness 'NotReady' }
            'database-not-assessed' { $database.TargetReadinesses.SqlServerOnAzureVM = New-Readiness 'NotAssessed' }
            'report-failed' { $report.Status='Failed' }
            'server-failed' { $server.Status='Failed' }
            'database-failed' { $database.Status='Failed' }
            'database-failed-with-ready' {
                $database.Status='Failed'
                $database.TargetReadinesses.SqlServerOnAzureVM = New-Readiness 'Ready'
            }
            'report-errors' { $report.Errors=@('Synthetic report error') }
            'server-errors' { $server.Errors=@('Synthetic server error') }
            'database-errors' { $database.Errors=@('Synthetic database error') }
            'missing-status' { $report.Remove('Status') }
            'empty-databases' { $server.Databases=@() }
        }
        $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $folder 'SqlAssessment.json') -Encoding UTF8
        '<!doctype html><title>VM assessment fixture</title>' | Set-Content -LiteralPath (Join-Path $folder 'SqlAssessment.html')
        "Instance name: $($case.name)\ERP`r`nSKU recommendation: SQL Server on Azure VM Standard_D8s_v5 Windows Standard Edition`r`nRecommendation reasons: Test" |
            Set-Content -LiteralPath (Join-Path $folder 'vm-console.txt')
    }
    & $scriptPath -ResultsRoot $vmResults -SummaryFolder $vmSummary -SkipPricing -PricingRegion westus3
    $vmCsv = @(Import-Csv -LiteralPath (Join-Path $vmSummary 'instance-assessment-summary.csv'))
    $vmPricing = @(Import-Csv -LiteralPath (Join-Path $vmSummary 'pricing-options.csv'))
    $vmHtml = Get-Content -LiteralPath (Join-Path $vmSummary 'assessment-summary.html') -Raw
    [xml]$vmTable = [regex]::Match($vmHtml, "(?s)<table class='instance-table'>.*?</table>").Value
    Assert-True ($vmCsv.Count -eq $vmCases.Count) 'All VM assessment fixtures appear in the summary'
    Assert-True ($vmPricing.Count -eq @($vmCases | Where-Object expected -eq 'Ready').Count) 'Only explicit or inferred Ready VM targets qualify for the pricing CSV'
    foreach ($case in $vmCases) {
        $record = $vmCsv | Where-Object ServerName -eq $case.name
        Assert-True ($record.AzureSqlIaaSCompatibility -eq $case.expected) "$($case.name): correct VM readiness"
        Assert-True ($record.AzureSqlIaaSReadyWithWarnings -eq [string]$case.warnings) "$($case.name): correct warning database count"
        Assert-True ($record.AzureSqlDatabaseCompatibility -eq 'NotReady' -and $record.AzureSqlManagedInstanceCompatibility -eq 'NotReady') 'VM fallback never changes SQL Database or Managed Instance statuses'
        $row = $vmTable.table.tbody.tr | Where-Object { $_.SelectSingleNode('td[2]').InnerText -eq $case.name }
        if ($case.expected -eq 'Not assessed') {
            Assert-True (-not $record.AzureSqlIaaSDetails -and $null -eq $row.td[12].a) 'Unassessed VM targets never link'
        } else {
            Assert-True ($record.AzureSqlIaaSDetails -like '*SqlAssessment.html' -and $row.td[12].a.href) 'Assessed VM targets link to the source HTML'
        }
        if ($case.expected -eq 'Ready') {
            Assert-True ($row.td[12].a.span.class -eq 'status ready') 'Ready VM targets display green rather than red'
            $pricingRow = $vmPricing | Where-Object ServerName -eq $case.name
            Assert-True ($pricingRow.ReadinessSource -eq $record.AzureSqlIaaSReadinessSource) 'Pricing CSV preserves explicit or inferred readiness provenance'
        }
    }
    $inferred = $vmCsv | Where-Object ServerName -eq 'clean'
    $native = $vmCsv | Where-Object ServerName -eq 'native-alias'
    Assert-True ($inferred.AzureSqlIaaSReadinessSource -like 'Completed assessment VM fallback*' -and
        $native.AzureSqlIaaSReadinessSource -eq 'Explicit JSON target readiness') 'Explicit and inferred VM readiness sources are distinguishable'
    Assert-True ($vmHtml -match "title='Completed assessment VM fallback") 'HTML tooltip exposes the fallback source'

    $emptyResults = Join-Path $testRoot 'empty-results'
    $emptySummary = Join-Path $testRoot 'new-parent\nested-summary'
    New-Item -ItemType Directory -Path $emptyResults | Out-Null
    Assert-True (-not (Test-Path -LiteralPath (Split-Path $emptySummary -Parent))) 'Summary parent does not exist before generation'
    & $scriptPath -ResultsRoot $emptyResults -SummaryFolder $emptySummary -SkipPricing
    Assert-True (Test-Path -LiteralPath $emptySummary -PathType Container) 'Missing summary folder and parents are created'
    $emptyHtml = Get-Content (Join-Path $emptySummary 'assessment-summary.html') -Raw
    Assert-True ($emptyHtml -match 'No compatibility assessment reports were found' -and $emptyHtml -match '0 source instances') 'Empty results show a clear empty state'
    $markerPath = Join-Path $emptySummary 'existing-file.txt'
    'Preserve existing contents' | Set-Content -LiteralPath $markerPath
    & $scriptPath -ResultsRoot $emptyResults -SummaryFolder $emptySummary -SkipPricing
    Assert-True ((Get-Content -LiteralPath $markerPath) -eq 'Preserve existing contents') 'Existing summary folder is reused without deleting unrelated files'
    $folderError = $null
    try {
        & $scriptPath -ResultsRoot $emptyResults -SummaryFolder $markerPath -SkipPricing
    } catch {
        $folderError = $_
    }
    Assert-True ($null -ne $folderError -and $folderError.Exception.Message -eq "Summary folder path is not a directory: $markerPath") 'File at summary folder path produces a clear error'
    Write-Host "All summary tests passed on PowerShell $($PSVersionTable.PSVersion)."
} finally {
    if ($KeepArtifacts) {
        Write-Host "Test artifacts retained at: $testRoot"
    } elseif (Test-Path $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
