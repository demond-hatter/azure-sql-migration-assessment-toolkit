# Azure SQL Migration Assessment Toolkit

This PowerShell toolkit helps collect the technical evidence needed to plan migrations from SQL Server to Azure SQL. It validates source connections, runs compatibility assessments, captures representative workload performance, generates Azure SKU recommendations, and consolidates the resulting files for review.

> **Note:** This toolkit is intended for scenarios where Azure Arc or an Azure Migrate appliance is not deployed and cannot be deployed quickly. If Azure Arc or Azure Migrate is already deployed, use that service to generate the assessment instead.

The toolkit can evaluate potential placement on:

- Azure SQL Database
- Azure SQL Managed Instance
- SQL Server on Azure Virtual Machines

The scripts are assessment-only. They read metadata and performance information from source SQL Server instances but do not migrate databases, provision Azure resources, or modify target environments.

## Requirements

### Assessment machine

Run the toolkit from a durable Windows machine, preferably a dedicated management workstation or VM, with:

- 64-bit Windows PowerShell 5.1 or PowerShell 7 or later.
- Outbound HTTPS access to PowerShell Gallery, `https://aka.ms`, and `https://dot.net` while installing prerequisites.
- Network connectivity and DNS resolution to every source SQL Server instance.
- Access to each SQL Server TCP port through network security groups, firewalls, and host firewalls.
- Sufficient local disk space for assessment and performance data.
- The ability to remain powered on with the PowerShell session open throughout performance collection.

### Software

The prerequisite script installs or validates:

- The `Az.DataMigration` PowerShell module.
- The Microsoft SQL assessment executable (`SqlAssessment.exe`).
- The x64 .NET runtime required by the downloaded assessment executable.

### SQL Server access

The toolkit supports Windows integrated authentication and SQL authentication. The assessment identity must be able to connect to each enabled instance and see all databases and metadata that should be assessed.

For complete results, the identity should have sufficient permissions to inspect server and database configuration, object definitions, and performance state. The connectivity report checks `VIEW SERVER STATE` and `VIEW ANY DEFINITION`; validate any least-privilege configuration on a pilot instance before assessing the full estate.

Named instances require SQL Browser resolution over UDP 1434 unless a fixed TCP port is supplied. Using a fixed TCP port in `servers.csv` is the most predictable configuration.

## Toolkit Contents

| File | Description |
|---|---|
| `servers.csv` | Source SQL Server inventory and connection settings. |
| `00-Install-Prerequisites.ps1` | Installs `Az.DataMigration`, downloads the assessment package, and validates its .NET runtime. |
| `01-Test-Connectivity.ps1` | Tests source connectivity, authentication, database visibility, SQL version, and key permissions. |
| `02-Run-CompatibilityAssessment.ps1` | Assesses sources sequentially in controlled batches. |
| `02-01-Run-CompatibilityAssessment-Parallel.ps1` | Assesses the sources within each batch concurrently for faster execution. |
| `03-Collect-PerformanceData.ps1` | Runs concurrent performance collectors for all enabled sources for a chosen duration. |
| `04-Generate-SkuRecommendations.ps1` | Generates sizing recommendations from a performance collection folder. |
| `05-Summarize-Results.ps1` | Produces CSV extracts, a file catalog, and an HTML summary. |
| `SummaryPricing.ps1` | Maps supported recommendations and captures public Azure retail pricing. Loaded by the summary script. |
| `summary-pricing.js` | Offline cost calculations and report controls; embedded into the generated HTML. |
| `Common.ps1` | Shared inventory, connection, naming, and prerequisite functions. Do not run directly. |
| `Common_old.ps1` | Retained legacy copy of shared functions; the workflow scripts do not load it. |

## Quick Start

Run commands from the toolkit directory.

### 1. Install prerequisites

If downloaded scripts are blocked, unblock this toolkit and allow execution for the current process:

```powershell
Get-ChildItem . -File | Unblock-File
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

Install and validate the required components:

```powershell
.\00-Install-Prerequisites.ps1 -InstallRequiredDotNetRuntime
```

Omit `-InstallRequiredDotNetRuntime` to report a missing runtime without installing it. Add `-Force` when intentionally refreshing the PowerShell module.

### 2. Configure the source inventory

Edit `servers.csv` and add one row per SQL Server instance:

| Column | Description |
|---|---|
| `Enabled` | `True`, `Yes`, `Y`, or `1` includes the source; other values skip it. |
| `DisplayName` | Optional friendly label used in console output and reports. |
| `ServerName` | Required resolvable hostname, FQDN, or IP address. |
| `InstanceName` | Named instance; leave blank for a default instance or when specifying `Port`. |
| `Port` | Fixed TCP port; do not populate both `Port` and `InstanceName`. |
| `Authentication` | `Windows`/`Integrated` or `Sql`; blank defaults to `Windows`. |
| `CredentialName` | Credential group for SQL authentication. Rows sharing a value reuse one prompt. |
| `Encrypt` | Whether to encrypt the SQL connection; blank defaults to `True`. |
| `TrustServerCertificate` | Whether to bypass certificate-chain validation; blank defaults to `False`. |

Example:

```csv
Enabled,DisplayName,ServerName,InstanceName,Port,Authentication,CredentialName,Encrypt,TrustServerCertificate
True,Finance SQL,finance-sql.example.com,,1433,Windows,,True,False
True,ERP SQL,erp-sql.example.com,ERP,,Sql,AssessmentLogin,True,False
```

SQL authentication credentials are requested interactively once per distinct `CredentialName`. Passwords are held in process memory and are not written to the inventory or result files.

### 3. Test connectivity

```powershell
.\01-Test-Connectivity.ps1
```

Review `results\connectivity-results.csv`. Resolve failed connections, missing databases, certificate issues, or insufficient permissions before continuing.

Use `-InventoryPath` to supply another inventory and `-OutputRoot` to change the result location:

```powershell
.\01-Test-Connectivity.ps1 -InventoryPath 'C:\Assessment\sources.csv' -OutputRoot 'D:\AssessmentResults'
```

### 4. Run compatibility assessment

Start with a small pilot. The sequential script is conservative and easier to troubleshoot:

```powershell
.\02-Run-CompatibilityAssessment.ps1 -BatchSize 4
```

For independent sources where the assessment machine and SQL estate can tolerate concurrent work, use the parallel version:

```powershell
.\02-01-Run-CompatibilityAssessment-Parallel.ps1 -BatchSize 4
```

`BatchSize` accepts 1 through 20. In the sequential script it controls output grouping; sources are still assessed one at a time. In the parallel script it is the maximum number of assessment processes running concurrently.

Each run creates a timestamped folder under `results`, with source-specific reports, console output, and error details.

### 5. Collect representative performance data

Run a pilot before starting a long collection:

```powershell
.\03-Collect-PerformanceData.ps1 -DurationHours 24
```

For a seven-day collection:

```powershell
.\03-Collect-PerformanceData.ps1 -DurationHours 168
```

The defaults are:

| Parameter | Default | Purpose |
|---|---:|---|
| `DurationHours` | 168 | Total time that collectors remain running. Valid range: 1-744 hours. |
| `PerformanceQueryIntervalSeconds` | 30 | Delay between performance samples. Valid range: 15-300 seconds. |
| `StaticQueryIntervalSeconds` | 3600 | Delay between static configuration samples. Valid range: 300-86400 seconds. |
| `NumberOfIterations` | 20 | Performance samples aggregated into each persisted batch. Valid range: 2-200. |

For example, a 30-second performance interval and 20 iterations produce an aggregated batch approximately every 10 minutes. The iteration count then resets and collection continues until `DurationHours` expires.

Keep the assessment machine and PowerShell session running for the entire collection. Use a period that includes normal peaks, scheduled jobs, reporting, ETL, maintenance, and relevant weekly or month-end patterns. The script displays the timestamped performance folder when collection finishes; retain that path for the next step.

### 6. Generate SKU recommendations

Pass the timestamped folder produced by performance collection:

```powershell
.\04-Generate-SkuRecommendations.ps1 `
  -PerformanceFolder 'D:\AssessmentResults\performance-YYYYMMDD-HHMMSS' `
  -TargetPercentile 95 `
  -ScalingFactor 125
```

By default, recommendations are generated separately for Azure SQL Database, Azure SQL Managed Instance, and SQL Server on Azure VMs. The optional `Any` target returns Microsoft's best fit, not a separate recommendation for every target. Available values for `-TargetPlatform` are:

- `AzureSqlDatabase`
- `AzureSqlManagedInstance`
- `AzureSqlVirtualMachine`
- `Any`

`TargetPercentile` selects the utilization percentile used for sizing. `ScalingFactor` applies capacity headroom as a percentage; for example, `125` adds 25 percent. `-ElasticStrategy` enables the cmdlet's elastic strategy for `AzureSqlDatabase` and `Any`. For `AzureSqlManagedInstance` and `AzureSqlVirtualMachine`, the script always passes `ElasticStrategy=false` and uses baseline sizing, even when the switch is supplied for a mixed-target run. Overridden requests produce a warning. The generated `recommendation-settings.json` records the requested switch in `ElasticStrategy` and the effective setting for each target in `ElasticStrategyByTarget`.

Run `.\tests\Test-Generate-SkuRecommendations.ps1` to validate strategy routing and settings with mocked recommendations (no SQL Server, Az.DataMigration installation, or Azure connection required).

Example for selected targets:

```powershell
.\04-Generate-SkuRecommendations.ps1 `
  -PerformanceFolder 'D:\AssessmentResults\performance-YYYYMMDD-HHMMSS' `
  -TargetPlatform AzureSqlManagedInstance,AzureSqlVirtualMachine
```

### 7. Summarize the results

```powershell
.\05-Summarize-Results.ps1 `
  -ResultsRoot '.\results' `
  -SummaryFolder '.\summary'
```

The script creates `SummaryFolder`, including missing parent directories, if it does not exist. An existing directory is reused; a path pointing to a file produces an error.

The summary folder contains:

- `assessment-summary.html`: responsive, light/dark browser report retaining Display Name, Server, Instance, and Databases, followed by distinct Azure SQL Database, Azure SQL Managed Instance, and SQL Server on Azure VM column groups. Each target has Compatibility, Warnings, SKU Recommendation, and Estimated cost/month columns. Ready appears in green with a check mark; Not Ready and Not Assessed appear in red with an X. Ready and Not Ready link to the underlying HTML assessment when available, otherwise to the source JSON assessment. Not Assessed never links to an assessment. SKU recommendations link to their HTML reports when available.
- `instance-assessment-summary.csv`: one row per source instance with SQL Database, Managed Instance, and Azure SQL IaaS compatibility results, detail links, and discovered SKU recommendations.
- `pricing-options.csv`: monthly USD pricing comparisons for Ready server/instance/target recommendations in each requested pricing region, including all supported plan/AHB combinations and reasons for unavailable options.
- `sku-recommendations.csv`: recommendations extracted from console output.
- `assessment-findings-filtered.csv`: JSON values likely related to findings, readiness, severity, and targets.
- `json-details.csv`: flattened leaf values from all JSON reports.
- `file-catalog.csv`: inventory of files under the results root.

The HTML report contains only the combined instance compatibility and SKU recommendation table. Standalone SKU recommendations and output inventory remain available as CSV exports, not additional HTML tables.

All generated report links, including the instance CSV's detail links and `AssessmentReport` path, are relative to the summary folder, not the shell's working directory. Keep `ResultsRoot` and `SummaryFolder` on the same drive or network share. To move or share the report, move both folders together while preserving their relative layout (for example, keep `results` and `summary` as siblings inside a common parent folder). Moving only the summary folder does not include its linked assessment or SKU files.

Warnings counts databases that are Ready for that target and have at least one warning finding, matching the existing SQL Database and Managed Instance warning-count behavior and extending it to Azure VM. It is not a total finding count; zero does not imply that the target was assessed or has no blockers. The instance CSV retains its existing fields and adds `AzureSqlIaaSReadyWithWarnings` for VM warning counts. Missing SKU recommendations display as **Not available** in the HTML report.

VM assessment JSON can omit VM readiness when there are no VM findings; the native HTML treats VMs as Ready in this case. The summary recognizes `SqlServerOnAzureVM`, `AzureSqlVirtualMachine`, and `AzureSqlIaaS` as VM target names. Explicit JSON readiness takes precedence, including Not Ready, Unknown, and Not Assessed. When VM readiness is absent, the summary infers Ready only for completed, error-free reports and servers with at least one database, all with Ready VM evidence or completed, error-free database assessments. VM findings categorized as Issue, BlockingIssue, or Critical make the inferred status Not Ready. Incomplete, failed, empty, or errored assessments are not inferred Ready. Warnings alone do not make a VM Not Ready.

The VM status tooltip and the instance CSV's `AzureSqlIaaSReadinessSource` distinguish explicit readiness from this completed-assessment fallback. Inferred Ready targets also qualify for the pricing CSV, whose `ReadinessSource` retains that distinction; missing SKU or pricing data still produces Unavailable costs, not fabricated prices. These readiness statuses indicate assessment compatibility, not a guarantee of migration or deployment success.

To validate summary generation with synthetic fixtures (no SQL Server or Azure connection required), run `.\tests\Test-Summarize-Results.ps1` in Windows PowerShell 5.1 or PowerShell 7. Add `-KeepArtifacts` to retain the generated reports for visual inspection; otherwise the tests clean up their temporary files.

#### Offline monthly cost estimates

Summary generation queries the public [Azure Retail Prices API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices), not a private Pricing Calculator endpoint. No Azure sign-in or subscription is required. Generation needs HTTPS access to `prices.azure.com`; only public product/SKU/region filters are sent, never source instance names or assessment files. The snapshot and calculation code are embedded in the HTML, so opening or sharing the finished report requires no server, API calls, credentials, or companion JavaScript file.

By default, generation captures available public-region prices for the supported recommended products. Limit the snapshot to selected ARM region names to reduce generation time and report size:

```powershell
.\05-Summarize-Results.ps1 `
  -ResultsRoot '.\results' `
  -SummaryFolder '.\summary' `
  -PricingRegion eastus,westus2,westeurope
```

Use `-SkipPricing` to generate the assessment report without network access or pricing. Cost cells remain blank until a region is selected. The region list comes from the embedded snapshot, and changing any pricing selection recalculates the costs locally. Regenerate the report to refresh prices; the report displays its snapshot timestamp. Pricing failures produce PowerShell warnings and a visible report warning, not invented or zero costs.

Region names are normalized to lowercase before querying the case-sensitive pricing API, so `-PricingRegion Westus3` and `-PricingRegion westus3` are equivalent. If an older report has an empty region list, regenerate it with the updated script (or use lowercase region names). A report with only global license prices has no regional compute rates to populate the selector.

##### Offline pricing comparison CSV

The same command generates `pricing-options.csv` alongside the HTML report. Use `-PricingRegion westus3` for one region, or pass several regions to compare them. Each row identifies the server, instance (blank for a default instance), target, full recommended SKU, region, and warning count. Only targets marked **Ready**, including Ready targets with warnings, are included; a server's readiness for one target does not include its Not Ready, Not Assessed, or Unknown targets.

Eight `*_MonthlyUSD` columns compare PAYG, 1-year reservations, 3-year reservations, and 1-year database savings plans, each with and without SQL Azure Hybrid Benefit. Values are monthly USD subtotals with two decimal places, no currency symbols or thousands separators. Reservations are amortized over their term, not shown as upfront purchase totals. Each option's `*_Details` column supplies its component breakdown, source meter IDs, exclusions, AHB eligibility assumptions, or reason for **Unavailable**. Unsupported plans and missing meters never fall back to PAYG or zero.

The export reuses the report's pricing snapshot without additional API calls or runtime dependencies. Snapshot timestamp, currency, hours/month, scope, and pricing query warnings are included for offline analysis. VM SQL edition comes from an explicit recommendation or, when unspecified, the source assessment's `Properties.ServerEdition`. The instance CSV retains `SourceSqlEdition`; the pricing CSV also records the resolved `VmSqlEdition` and `VmSqlEditionSource`. Identical VM recommendations on different instances retain their own assessed edition and license price. An unspecified VM OS defaults to Windows Server, including Windows licensing; this assumption appears in the cost details. Explicit Linux recommendations retain Linux pricing. Missing hardware or SQL edition is not guessed; affected options are unavailable. Browser selections do not change the CSV. Regenerate after updating recommendations or to refresh prices.

Without `-PricingRegion`, the CSV covers the public regions with compute rates in the snapshot. With an explicit region, Ready targets are exported even when regional prices are missing or `-SkipPricing` is set, with unavailable options and reasons. If no Ready targets or no regions are available, the CSV contains headers only and generation emits a warning; previous CSV rows are replaced, not retained.

Options:

- **Pay as you go** is the default.
- **1-year RI** and **3-year RI** amortize the published reservation price over 12 or 36 months, respectively.
- **1-year database savings plan** uses the compute meter's published 1-year `savingsPlan` rate. It does not apply to SQL Server on Azure VMs; that combination displays **Unavailable** rather than silently reverting to PAYG.
- **Azure Hybrid Benefit** removes the separate SQL license charge, assuming sufficient eligible SQL Server licenses with Software Assurance or subscription rights. It does not waive Windows Server licensing.
- No custom percentage discount is offered.

Estimates assume **USD**, **730 hours/month**, full utilization of the selected commitment, and one displayed recommended resource (not every database on its source server). RI and savings-plan discounts apply to eligible compute only; SQL licensing and storage stay at their published rates. Each populated cell exposes its monthly component breakdown, source meter IDs, and exclusions.

Supported mappings include provisioned SQL Database and Managed Instance vCore recommendations with recognizable service tier and hardware, and identifiable ARM VM sizes. Native VM names such as `D2as_v4` are normalized to `Standard_D2as_v4`; already-prefixed names and constrained-vCPU sizes are also supported. VM prices match the ARM size and its retail SKU name (for example, `D2as v4`), excluding Spot and Low Priority meters. Regenerate older reports to capture these VM meters. When hardware is absent, explicitly select Standard-series (Gen5) in the report; it is never assumed silently. VM OS uses the recommendation when specified and otherwise defaults to Windows Server; there is no OS selector. VM SQL edition uses an explicit recommendation first, otherwise the assessed source server's edition; there is no SQL edition selector. Standard, Enterprise, and Web source editions map to their public SQL license meters. Developer, Express, missing, and unknown source editions are not silently converted to paid editions or assumed to have free SQL licensing; non-AHB estimates remain Unavailable with a reason when no supported edition can be resolved. AHB still requires sufficient eligible licenses and never waives Windows licensing. Linux estimates exclude paid distribution licensing. [Next-gen General Purpose MI uses General Purpose baseline billing](https://learn.microsoft.com/azure/azure-sql/managed-instance/service-tiers-next-gen-general-purpose-use); extra memory and IOPS are excluded.

Recommended SQL storage GB is priced when the appropriate storage meter exists. VM managed disks are included only when the recommendation specifies recognizable disk SKUs (P/E/S series), counts, and LRS/ZRS redundancy; otherwise the breakdown explicitly excludes the unresolved storage. Disk transactions, backups, networking, tax, support, additional HA/DR replicas, and usage-based IO are excluded. Serverless, DTU, elastic pools, zone-redundant SQL, unknown hardware, missing regional/term meters, and ambiguous matches display **Unavailable** where they cannot be priced reliably. A priced subtotal with excluded components is not an all-in deployment quote, and a meter's presence does not guarantee resource availability in that region.

VM SQL licensing uses the published `1-4 vCPU VM` meter for sizes with up to four vCPUs. Native `Available vCPU` counts take precedence over digits in the size name, which do not always represent core counts for older VM families.

Run `.\tests\Test-SummaryPricing.ps1` for deterministic snapshot/mapping tests with mocked API responses (no network required). Add `-KeepArtifacts`, open the printed browser test report, and inspect `document.body.dataset.pricingTests` for `passed`; the embedded browser regression suite checks cost arithmetic, discounts, Hybrid Benefit, missing prices, and offline UI changes.

## Output and Data Handling

Most scripts create timestamped folders so multiple runs can coexist. Assessment output can contain server names, database names, object names, configuration, and workload characteristics. Store it in an access-controlled location and follow organizational retention requirements.

Do not treat a generated SKU as an automatic migration decision. Review compatibility blockers, cross-database and instance-level dependencies, high availability and disaster recovery needs, latency, storage growth, licensing, security, and operational requirements before selecting a target.

Repeat assessment after material workload changes, major remediation, consolidation, or application releases.

## Troubleshooting

- Run `01-Test-Connectivity.ps1` first and do not continue with failed or incomplete sources.
- For named-instance failures, configure a fixed TCP port and place it in `Port`, leaving `InstanceName` blank.
- If prerequisite validation reports a missing runtime, rerun `00-Install-Prerequisites.ps1 -InstallRequiredDotNetRuntime`, then open a new 64-bit PowerShell session if requested.
- Review source-specific `*-console.txt` and `*-error.txt` files when an assessment or collector fails.
- Reduce parallel `BatchSize` if the assessment machine or source estate experiences excessive load.
- Preserve interrupted performance folders for diagnosis, but generate recommendations only from collection periods whose workload coverage and data quality are understood.

## Microsoft Documentation

- [Az.DataMigration PowerShell module](https://learn.microsoft.com/powershell/module/az.datamigration/)
- [Compatibility assessment cmdlet](https://learn.microsoft.com/powershell/module/az.datamigration/get-azdatamigrationassessment)
- [Performance collection cmdlet](https://learn.microsoft.com/powershell/module/az.datamigration/get-azdatamigrationperformancedatacollection)
- [SKU recommendation cmdlet](https://learn.microsoft.com/powershell/module/az.datamigration/get-azdatamigrationskurecommendation)
- [Azure SQL assessment calculation methodology](https://learn.microsoft.com/azure/migrate/concepts-azure-sql-assessment-calculation)