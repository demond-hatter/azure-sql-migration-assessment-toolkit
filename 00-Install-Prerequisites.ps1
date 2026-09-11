[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$InstallRequiredDotNetRuntime
)
$ErrorActionPreference = 'Stop'

function Get-DotNetExecutables {
    # Check every .NET host. A system-wide host can appear first in PATH even
    # when the required runtime is installed under the current user's profile.
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe'),
        (Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'),
        (Get-Command dotnet -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
    return @($candidates)
}

function Test-RequiredRuntime {
    param(
        [Parameter(Mandatory)][string]$FrameworkName,
        [Parameter(Mandatory)][version]$FrameworkVersion
    )
    $dotnetHosts = Get-DotNetExecutables
    if (-not $dotnetHosts) { return $false }
    $majorMinor = "$($FrameworkVersion.Major).$($FrameworkVersion.Minor)."
    foreach ($dotnet in $dotnetHosts) {
        $installed = & $dotnet --list-runtimes 2>$null
        if ($installed | Where-Object { $_ -like "$FrameworkName $majorMinor*" }) {
            Write-Host "Runtime located using: $dotnet"
            return $true
        }
    }
    return $false
}

function Install-RequiredRuntime {
    param(
        [Parameter(Mandatory)][string]$FrameworkName,
        [Parameter(Mandatory)][version]$FrameworkVersion
    )
    $runtimeMap = @{
        'Microsoft.NETCore.App'       = 'dotnet'
        'Microsoft.WindowsDesktop.App' = 'windowsdesktop'
        'Microsoft.AspNetCore.App'    = 'aspnetcore'
    }
    if (-not $runtimeMap.ContainsKey($FrameworkName)) {
        throw "Automatic installation is not configured for framework '$FrameworkName'."
    }

    $installScript = Join-Path $env:TEMP 'dotnet-install.ps1'
    $installDir = Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet'
    $channel = "$($FrameworkVersion.Major).$($FrameworkVersion.Minor)"
    Write-Host "Installing $FrameworkName $channel for the current user..."
    Invoke-WebRequest 'https://dot.net/v1/dotnet-install.ps1' -OutFile $installScript -UseBasicParsing
    & $installScript -Channel $channel -Runtime $runtimeMap[$FrameworkName] -Architecture x64 -InstallDir $installDir -NoPath
    if ($LASTEXITCODE -ne 0) { throw "The .NET runtime installer returned exit code $LASTEXITCODE." }

    $env:DOTNET_ROOT = $installDir
    $env:DOTNET_ROOT_X64 = $installDir
    if (($env:Path -split ';') -notcontains $installDir) { $env:Path = "$installDir;$env:Path" }
    [Environment]::SetEnvironmentVariable('DOTNET_ROOT', $installDir, 'User')
    [Environment]::SetEnvironmentVariable('DOTNET_ROOT_X64', $installDir, 'User')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (($userPath -split ';') -notcontains $installDir) {
        [Environment]::SetEnvironmentVariable('Path', "$installDir;$userPath", 'User')
    }
}

Write-Host 'Checking PowerShell and package prerequisites...'
if ($PSVersionTable.PSVersion.Major -lt 5) { throw 'PowerShell 5.1 or later is required.' }
if (-not [Environment]::Is64BitProcess) { throw 'Run the toolkit from a 64-bit PowerShell session.' }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
    Install-PackageProvider NuGet -Scope CurrentUser -Force | Out-Null
}

$gallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
if ($gallery -and $gallery.InstallationPolicy -ne 'Trusted') {
    Write-Warning 'PSGallery is not trusted. PowerShell may ask you to approve the repository.'
}

$params = @{ Name='Az.DataMigration'; Scope='CurrentUser'; AllowClobber=$true }
if ($Force) { $params.Force = $true }
Install-Module @params
Import-Module Az.DataMigration -Force
$module = Get-Module Az.DataMigration
Write-Host "Installed Az.DataMigration $($module.Version)."

# The cmdlet downloads SqlAssessment.exe on first use. Download it now so its
# exact runtime requirement can be validated before an assessment is started.
$assessmentRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\SqlAssessment'
$downloads = Join-Path $assessmentRoot 'Downloads'
$assessmentExe = Get-ChildItem $downloads -Recurse -Filter SqlAssessment.exe -ErrorAction SilentlyContinue |
    Select-Object -First 1

if (-not $assessmentExe) {
    New-Item -ItemType Directory -Path $downloads -Force | Out-Null
    $package = Join-Path $downloads 'SqlAssessment.zip'
    Write-Host 'Downloading the Microsoft SQL assessment package...'
    Invoke-WebRequest 'https://aka.ms/sqlassessmentpackage' -OutFile $package -UseBasicParsing
    Expand-Archive $package -DestinationPath $downloads -Force
    $assessmentExe = Get-ChildItem $downloads -Recurse -Filter SqlAssessment.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1
}
if (-not $assessmentExe) { throw "SqlAssessment.exe was not found after extracting the assessment package under $downloads." }
Write-Host "SQL assessment executable: $($assessmentExe.FullName)"

$runtimeConfig = Get-ChildItem $assessmentExe.DirectoryName -Filter '*.runtimeconfig.json' -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $runtimeConfig) { throw "No .NET runtime configuration was found next to $($assessmentExe.FullName)." }
$config = Get-Content $runtimeConfig.FullName -Raw | ConvertFrom-Json
$requirements = @()
if ($config.runtimeOptions.framework) { $requirements += $config.runtimeOptions.framework }
if ($config.runtimeOptions.frameworks) { $requirements += $config.runtimeOptions.frameworks }
if (-not $requirements) { throw "The runtime configuration does not identify a framework: $($runtimeConfig.FullName)" }

foreach ($requirement in $requirements) {
    $requiredVersion = [version]$requirement.version
    Write-Host "Required runtime: $($requirement.name) $requiredVersion"
    if (-not (Test-RequiredRuntime -FrameworkName $requirement.name -FrameworkVersion $requiredVersion)) {
        if ($InstallRequiredDotNetRuntime) {
            Install-RequiredRuntime -FrameworkName $requirement.name -FrameworkVersion $requiredVersion
        }
        else {
            throw @"
Missing required runtime: $($requirement.name) $($requiredVersion.Major).$($requiredVersion.Minor).x (x64).

Install the matching x64 .NET runtime, or rerun this script with:
  .\00-Install-Prerequisites.ps1 -InstallRequiredDotNetRuntime
"@
        }
    }
    if (-not (Test-RequiredRuntime -FrameworkName $requirement.name -FrameworkVersion $requiredVersion)) {
        throw "The required runtime $($requirement.name) $($requiredVersion.Major).$($requiredVersion.Minor).x is still unavailable. Close PowerShell, open a new 64-bit session, and rerun this check."
    }
    Write-Host "Runtime check passed: $($requirement.name) $($requiredVersion.Major).$($requiredVersion.Minor).x"
}

Write-Host 'Prerequisite check completed successfully.' -ForegroundColor Green
