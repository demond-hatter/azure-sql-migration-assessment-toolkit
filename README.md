# Azure SQL Migration Assessment Toolkit

This PowerShell toolkit helps collect the technical evidence needed to plan migrations from SQL Server to Azure SQL. It validates source connections, runs compatibility assessments, captures representative workload performance, generates Azure SKU recommendations, and consolidates the resulting files for review.

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

By default, recommendations are generated separately for Azure SQL Database, Azure SQL Managed Instance, and the Microsoft best-fit `Any` target. Available values for `-TargetPlatform` are:

- `AzureSqlDatabase`
- `AzureSqlManagedInstance`
- `AzureSqlVirtualMachine`
- `Any`

`TargetPercentile` selects the utilization percentile used for sizing. `ScalingFactor` applies capacity headroom as a percentage; for example, `125` adds 25 percent. `-ElasticStrategy` enables the cmdlet's elastic strategy when that behavior is desired.

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

The summary folder contains:

- `assessment-summary.html`: browser-friendly overview of recommendations and output files.
- `sku-recommendations.csv`: recommendations extracted from console output.
- `assessment-findings-filtered.csv`: JSON values likely related to findings, readiness, severity, and targets.
- `json-details.csv`: flattened leaf values from all JSON reports.
- `file-catalog.csv`: inventory of files under the results root.

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