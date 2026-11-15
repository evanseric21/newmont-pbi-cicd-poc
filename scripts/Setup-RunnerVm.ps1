<#
.SYNOPSIS
  Bootstraps the Windows VM as the GitHub self-hosted runner (label: pbi) for the Power BI CI/CD POC.
  Run in an elevated Windows PowerShell 5.1 session ON THE VM.

.PARAMETER RepoUrl
  e.g. https://github.com/evanseric21/newmont-pbi-cicd-poc

.PARAMETER RunnerToken
  Registration token from: gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token --jq .token
  (valid for 1 hour).

.NOTES
  Installs: Git, Python 3.12, Tabular Editor 2 (portable), ADOMD.NET, GitHub Actions runner (as a Windows service).
  The on-premises data gateway is installed separately (interactive sign-in) - see docs/Setup-Guide.md step 4.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $RepoUrl,
    [Parameter(Mandatory)] [string] $RunnerToken,
    [string] $RunnerName = $env:COMPUTERNAME,
    [string] $ToolsRoot = 'C:\tools',
    [string] $RunnerRoot = 'C:\actions-runner'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
New-Item -ItemType Directory -Force -Path $ToolsRoot, $RunnerRoot | Out-Null
$gh = @{ 'User-Agent' = 'newmont-poc-setup' }

function Get-LatestAsset([string] $repo, [string] $pattern) {
    $rel = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -Headers $gh
    $asset = $rel.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
    if (-not $asset) { throw "No asset matching '$pattern' in $repo latest release" }
    $asset
}

# --- Git ---
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host 'Installing Git...'
    $a = Get-LatestAsset 'git-for-windows/git' '^Git-[\d\.]+-64-bit\.exe$'
    $exe = Join-Path $env:TEMP $a.name
    Invoke-WebRequest $a.browser_download_url -OutFile $exe -UseBasicParsing
    Start-Process $exe -ArgumentList '/VERYSILENT','/NORESTART','/NOCANCEL','/SP-' -Wait
}

# --- Python (all users, on PATH so the runner service account can use it) ---
if (-not (Test-Path 'C:\Program Files\Python312\python.exe')) {
    Write-Host 'Installing Python 3.12...'
    $exe = Join-Path $env:TEMP 'python-3.12.7-amd64.exe'
    Invoke-WebRequest 'https://www.python.org/ftp/python/3.12.7/python-3.12.7-amd64.exe' -OutFile $exe -UseBasicParsing
    Start-Process $exe -ArgumentList '/quiet','InstallAllUsers=1','PrependPath=1','Include_test=0' -Wait
}

# --- Tabular Editor 2 (portable) for Best Practice Analyzer ---
$te = Join-Path $ToolsRoot 'TabularEditor\TabularEditor.exe'
if (-not (Test-Path $te)) {
    Write-Host 'Installing Tabular Editor 2...'
    $a = Get-LatestAsset 'TabularEditor/TabularEditor' '^TabularEditor\.Portable\.zip$'
    $zip = Join-Path $env:TEMP $a.name
    Invoke-WebRequest $a.browser_download_url -OutFile $zip -UseBasicParsing
    Expand-Archive $zip -DestinationPath (Join-Path $ToolsRoot 'TabularEditor') -Force
}

# --- ADOMD.NET (used by scripts/Invoke-ModelTests.ps1) ---
$adomd = Join-Path $ToolsRoot 'adomd'
if (-not (Get-ChildItem $adomd -Recurse -Filter 'Microsoft.AnalysisServices.AdomdClient.dll' -ErrorAction SilentlyContinue)) {
    Write-Host 'Installing ADOMD.NET...'
    $pkg = 'microsoft.analysisservices.adomdclient.retail.amd64'
    $ver = (Invoke-RestMethod "https://api.nuget.org/v3-flatcontainer/$pkg/index.json").versions | Where-Object { $_ -notmatch '-' } | Select-Object -Last 1
    New-Item -ItemType Directory -Force -Path $adomd | Out-Null
    $zip = Join-Path $adomd "$pkg.$ver.zip"
    Invoke-WebRequest "https://api.nuget.org/v3-flatcontainer/$pkg/$ver/$pkg.$ver.nupkg" -OutFile $zip -UseBasicParsing
    Expand-Archive $zip -DestinationPath (Join-Path $adomd $ver) -Force
}

[Environment]::SetEnvironmentVariable('TABULAR_EDITOR_PATH', $te, 'Machine')
[Environment]::SetEnvironmentVariable('ADOMD_PATH', $adomd, 'Machine')

# --- GitHub Actions runner (service) ---
if (-not (Test-Path (Join-Path $RunnerRoot '.runner'))) {
    Write-Host 'Installing GitHub Actions runner...'
    $a = Get-LatestAsset 'actions/runner' '^actions-runner-win-x64-[\d\.]+\.zip$'
    $zip = Join-Path $env:TEMP $a.name
    Invoke-WebRequest $a.browser_download_url -OutFile $zip -UseBasicParsing
    Expand-Archive $zip -DestinationPath $RunnerRoot -Force
    Push-Location $RunnerRoot
    try {
        .\config.cmd --unattended --url $RepoUrl --token $RunnerToken --name $RunnerName `
            --labels 'pbi' --work '_work' --runasservice --replace
        if ($LASTEXITCODE) { throw "Runner configuration failed ($LASTEXITCODE)" }
    } finally { Pop-Location }
}

Write-Host "`nDone. Runner '$RunnerName' registered with labels: self-hosted, Windows, X64, pbi"
Write-Host 'Restart the runner service once so it picks up the new PATH/machine variables:'
Write-Host '  Get-Service actions.runner.* | Restart-Service'
