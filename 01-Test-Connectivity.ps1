[CmdletBinding()]
param(
    [string]$InventoryPath = (Join-Path $PSScriptRoot 'servers.csv'),
    [string]$OutputRoot = (Join-Path $PSScriptRoot 'results')
)
. (Join-Path $PSScriptRoot 'Common.ps1')
$inventory = Import-AssessmentInventory $InventoryPath
$connections = Get-AssessmentConnectionStrings $inventory
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$results = foreach ($item in $connections) {
    $started = Get-Date
    try {
        $connection = [System.Data.SqlClient.SqlConnection]::new($item.ConnectionString)
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandTimeout = 30
        $command.CommandText = @"
SELECT
  CAST(SERVERPROPERTY('ServerName') AS nvarchar(256)) AS ServerName,
  CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)) AS ProductVersion,
  CAST(SERVERPROPERTY('Edition') AS nvarchar(256)) AS Edition,
  (SELECT COUNT(*) FROM sys.databases WHERE database_id > 4) AS UserDatabaseCount,
  HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE') AS HasViewServerState,
  HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW ANY DEFINITION') AS HasViewAnyDefinition;
"@
        $reader = $command.ExecuteReader()
        [void]$reader.Read()
        [pscustomobject]@{
            InventoryName=$item.Name; DataSource=$item.DataSource; Status='Connected'
            ServerName=$reader['ServerName']; ProductVersion=$reader['ProductVersion']; Edition=$reader['Edition']
            UserDatabaseCount=$reader['UserDatabaseCount']; HasViewServerState=$reader['HasViewServerState']
            HasViewAnyDefinition=$reader['HasViewAnyDefinition']; ElapsedSeconds=[math]::Round(((Get-Date)-$started).TotalSeconds,2)
            Error=$null
        }
        $reader.Close(); $connection.Close()
    }
    catch {
        [pscustomobject]@{
            InventoryName=$item.Name; DataSource=$item.DataSource; Status='Failed'; ServerName=$null
            ProductVersion=$null; Edition=$null; UserDatabaseCount=$null; HasViewServerState=$null
            HasViewAnyDefinition=$null; ElapsedSeconds=[math]::Round(((Get-Date)-$started).TotalSeconds,2)
            Error=$_.Exception.Message
        }
    }
}
$path = Join-Path $OutputRoot 'connectivity-results.csv'
$results | Export-Csv $path -NoTypeInformation
$results | Format-Table InventoryName,Status,ProductVersion,UserDatabaseCount,HasViewServerState,HasViewAnyDefinition -AutoSize
Write-Host "Results written to $path"
if ($results.Status -contains 'Failed') { exit 2 }
