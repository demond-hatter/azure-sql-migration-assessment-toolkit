Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Import-AssessmentInventory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { throw "Inventory file not found: $Path" }
    $rows = Import-Csv $Path | Where-Object { $_.Enabled -match '^(1|true|yes|y)$' }
    if (-not $rows) { throw 'The inventory contains no enabled servers.' }
    foreach ($row in $rows) {
        if (-not $row.ServerName) { throw 'Every enabled row requires ServerName.' }
        if (-not $row.Authentication) { $row.Authentication = 'Windows' }
        if (-not $row.CredentialName) { $row.CredentialName = 'DefaultSqlCredential' }
        if (-not $row.Encrypt) { $row.Encrypt = 'True' }
        if (-not $row.TrustServerCertificate) { $row.TrustServerCertificate = 'False' }
    }
    return @($rows)
}

function Get-SqlDataSource {
    param($Row)
    if ($Row.InstanceName -and $Row.Port) {
        throw "Specify either InstanceName or Port, not both, for $($Row.ServerName)."
    }
    if ($Row.InstanceName) { return "$($Row.ServerName)\$($Row.InstanceName)" }
    if ($Row.Port) { return "tcp:$($Row.ServerName),$($Row.Port)" }
    return $Row.ServerName
}

function ConvertTo-Boolean {
    param([string]$Value, [bool]$Default = $false)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }
    return $Value -match '^(1|true|yes|y)$'
}

function Get-AssessmentConnectionStrings {
    param([Parameter(Mandatory)][object[]]$Inventory)
    $credentials = @{}
    $results = @()

    foreach ($row in $Inventory) {
        $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
        $builder['Data Source'] = Get-SqlDataSource $row
        $builder['Initial Catalog'] = 'master'
        # SqlAssessment.exe tokenizes its connection-string argument. Avoid
        # spaces in values because quoted Application Name values can be split
        # into separate tokens (for example, the stray token "SQL").
        $builder['Application Name'] = 'AzureSqlMigrationAssessment'
        $builder['Persist Security Info'] = $false
        $builder['Connect Timeout'] = 30
        $builder['Encrypt'] = ConvertTo-Boolean $row.Encrypt $true
        $builder['TrustServerCertificate'] = ConvertTo-Boolean $row.TrustServerCertificate $false

        if ($row.Authentication -match '^(Windows|Integrated)$') {
            $builder['Integrated Security'] = $true
        }
        elseif ($row.Authentication -match '^Sql$') {
            $key = $row.CredentialName
            if (-not $credentials.ContainsKey($key)) {
                $credentials[$key] = Get-Credential -Message "Enter the SQL login for credential group '$key'. The credential is held only in memory."
            }
            $credential = $credentials[$key]
            $builder['Integrated Security'] = $false
            $builder['User ID'] = $credential.UserName
            $builder['Password'] = $credential.GetNetworkCredential().Password
        }
        else {
            throw "Unsupported Authentication '$($row.Authentication)' for $($row.ServerName). Use Windows or Sql."
        }

        $results += [pscustomobject]@{
            Name = if ($row.DisplayName) { $row.DisplayName } else { Get-SqlDataSource $row }
            ServerName = $row.ServerName
            InstanceName = $row.InstanceName
            Port = $row.Port
            DataSource = Get-SqlDataSource $row
            ConnectionString = $builder.ConnectionString
        }
    }
    return $results
}

function Resolve-NamedInstanceTcpEndpoints {
    param([Parameter(Mandatory)][object[]]$Connections)
    $resolved = @()

    foreach ($item in $Connections) {
        if (-not $item.InstanceName -or $item.Port) {
            $resolved += $item
            continue
        }

        $connectionStringText = $item.ConnectionString.PSObject.BaseObject.ToString()
        $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new($connectionStringText)
        $normalDataSource = $item.DataSource.PSObject.BaseObject.ToString()
        $tcpDataSource = "tcp:$($item.ServerName)\$($item.InstanceName)"
        $candidateDataSources = [System.Collections.Generic.List[string]]::new()
        $candidateDataSources.Add($normalDataSource)
        if (-not [string]::Equals($normalDataSource, $tcpDataSource, [System.StringComparison]::OrdinalIgnoreCase)) {
            $candidateDataSources.Add($tcpDataSource)
        }
        $resolvedPort = $null
        $diagnostics = @()

        foreach ($candidate in $candidateDataSources) {
            $connection = $null
            try {
                # First try the same named-instance format that passed the
                # connectivity test. Some older instances reject an explicit
                # tcp: prefix during SQL Browser resolution.
                $candidateText = $candidate.ToString()
                $builder['Data Source'] = $candidateText
                $connection = [System.Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
                $connection.Open()
                $command = $connection.CreateCommand()
                $command.CommandTimeout = 30
                $command.CommandText = "SELECT CONNECTIONPROPERTY('local_tcp_port');"
                $portValue = $command.ExecuteScalar()
                if ($null -ne $portValue -and $portValue -isnot [System.DBNull]) {
                    $basePortValue = $portValue.PSObject.BaseObject
                    $resolvedPort = [System.Convert]::ToInt32($basePortValue)
                }
                if ($resolvedPort) { break }
                $diagnostics += "$($candidateText) connected, but the session did not use TCP."
            }
            catch {
                $diagnostics += "$($candidateText) failed: $($_.Exception.Message)"
            }
            finally {
                if ($connection) { $connection.Dispose() }
            }
        }

        if ($resolvedPort) {
            $builder['Data Source'] = "tcp:$($item.ServerName),$resolvedPort"
            $resolved += [pscustomobject]@{
                Name = $item.Name
                ServerName = $item.ServerName
                InstanceName = $item.InstanceName
                Port = [string]$resolvedPort
                DataSource = "tcp:$($item.ServerName),$resolvedPort"
                OriginalDataSource = $item.DataSource
                ConnectionString = $builder.ConnectionString
            }
            Write-Host "Resolved $($item.ServerName)\$($item.InstanceName) to tcp:$($item.ServerName),$resolvedPort"
        }
        else {
            throw @"
Unable to resolve named instance $($item.ServerName)\$($item.InstanceName) to a TCP port.

$($diagnostics -join [Environment]::NewLine)

Confirm TCP/IP is enabled and SQL Browser/UDP 1434 is reachable, or use the
recommended approach: configure/find the instance's fixed TCP port, place it
in the Port column in servers.csv, and leave InstanceName blank.
"@
        }
    }
    return @($resolved)
}

function Get-SafeSourceName {
    param([Parameter(Mandatory)]$Connection)
    $name = $Connection.ServerName
    if ($Connection.InstanceName) {
        $name += "_$($Connection.InstanceName)"
    }
    elseif ($Connection.Port) {
        $name += "_port$($Connection.Port)"
    }
    return ($name -replace '[^A-Za-z0-9._-]', '_').Trim('_')
}

function Get-SqlAssessmentExecutable {
    $downloads = Join-Path $env:LOCALAPPDATA 'Microsoft\SqlAssessment\Downloads'
    $executable = Get-ChildItem $downloads -Recurse -Filter SqlAssessment.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $executable) {
        throw 'SqlAssessment.exe was not found. Run 00-Install-Prerequisites.ps1 first.'
    }
    return $executable.FullName
}

function Assert-DataMigrationModule {
    $userDotNet = Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet'
    if (Test-Path (Join-Path $userDotNet 'dotnet.exe')) {
        # SqlAssessment.exe is a native apphost. Point it at a current-user
        # runtime even when an older system-wide dotnet host is first in PATH.
        $env:DOTNET_ROOT = $userDotNet
        $env:DOTNET_ROOT_X64 = $userDotNet
        if (($env:Path -split ';') -notcontains $userDotNet) {
            $env:Path = "$userDotNet;$env:Path"
        }
    }
    $module = Get-Module -ListAvailable Az.DataMigration | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $module) { throw 'Az.DataMigration is not installed. Run 00-Install-Prerequisites.ps1 first.' }
    Import-Module Az.DataMigration -Force
}

function New-TimestampedFolder {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Name)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $path = Join-Path $Root "$Name-$stamp"
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return (Resolve-Path $path).Path
}
