<#
.SYNOPSIS
  Runs data-validation and RLS/OLS checks against a deployed semantic model over the XMLA endpoint.

.DESCRIPTION
  * Data validation: compares DAX results (row counts, key totals) to the source database.
  * RLS/OLS: connects with the "Roles=" connection-string property so the query is evaluated
    as a member of that role, then asserts the expected rows / blocked columns.
  Requires Windows PowerShell 5.1 (ADOMD.NET for .NET Framework) - i.e. the self-hosted Windows runner.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkspaceName,
    [Parameter(Mandatory)] [string] $SemanticModelName,
    [Parameter(Mandatory)] [string] $SqlServer,
    [Parameter(Mandatory)] [string] $SqlDatabase,
    [Parameter(Mandatory)] [string] $SqlSchema,
    [string] $TestFile = (Join-Path $PSScriptRoot '..\tests\model-tests.json'),
    [string] $AdomdPath = $(if ($env:ADOMD_PATH) { $env:ADOMD_PATH } else { 'C:\tools\adomd' })
)
$ErrorActionPreference = 'Stop'

foreach ($v in 'AZURE_TENANT_ID','AZURE_CLIENT_ID','AZURE_CLIENT_SECRET','SQL_READER_USER','SQL_READER_PASSWORD') {
    if (-not [Environment]::GetEnvironmentVariable($v)) { throw "Missing environment variable $v" }
}

# ---------- ADOMD.NET ----------
function Initialize-Adomd {
    $dll = Get-ChildItem -Path $AdomdPath -Recurse -Filter 'Microsoft.AnalysisServices.AdomdClient.dll' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\lib\\net4' } | Select-Object -First 1
    if (-not $dll) {
        Write-Host "ADOMD.NET not found in $AdomdPath - downloading from NuGet"
        $pkg = 'microsoft.analysisservices.adomdclient.retail.amd64'
        $ver = (Invoke-RestMethod "https://api.nuget.org/v3-flatcontainer/$pkg/index.json").versions |
            Where-Object { $_ -notmatch '-' } | Select-Object -Last 1
        New-Item -ItemType Directory -Force -Path $AdomdPath | Out-Null
        $zip = Join-Path $AdomdPath "$pkg.$ver.zip"
        Invoke-WebRequest "https://api.nuget.org/v3-flatcontainer/$pkg/$ver/$pkg.$ver.nupkg" -OutFile $zip -UseBasicParsing
        Expand-Archive $zip -DestinationPath (Join-Path $AdomdPath $ver) -Force
        $dll = Get-ChildItem -Path $AdomdPath -Recurse -Filter 'Microsoft.AnalysisServices.AdomdClient.dll' |
            Where-Object { $_.FullName -match '\\lib\\net4' } | Select-Object -First 1
    }
    Add-Type -Path $dll.FullName
}

function Invoke-Dax([string] $Dax, [string] $Role) {
    $cs = "Data Source=powerbi://api.powerbi.com/v1.0/myorg/$WorkspaceName;Initial Catalog=$SemanticModelName;" +
          "User ID=app:$($env:AZURE_CLIENT_ID)@$($env:AZURE_TENANT_ID);Password=$($env:AZURE_CLIENT_SECRET)"
    if ($Role) { $cs += ";Roles=$Role" }
    $conn = New-Object Microsoft.AnalysisServices.AdomdClient.AdomdConnection($cs)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Dax
        $reader = $cmd.ExecuteReader()
        try {
            if ($reader.Read()) { return $reader.GetValue(0) } else { return $null }
        } finally { $reader.Close() }
    } finally { $conn.Close() }
}

function Invoke-SqlScalar([string] $Query) {
    $cs = "Server=tcp:$SqlServer,1433;Database=$SqlDatabase;User ID=$($env:SQL_READER_USER);" +
          "Password=$($env:SQL_READER_PASSWORD);Encrypt=True;TrustServerCertificate=False;Connection Timeout=30"
    $conn = New-Object System.Data.SqlClient.SqlConnection($cs)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Query.Replace('{schema}', $SqlSchema)
        return $cmd.ExecuteScalar()
    } finally { $conn.Close() }
}

function Test-Case($case, [string] $category) {
    $result = [ordered]@{ Category = $category; Name = $case.name; Role = $case.role; Actual = ''; Expected = ''; Passed = $false }
    try {
        $actual = Invoke-Dax -Dax $case.dax -Role $case.role
        if ($case.expectError) {
            $result.Expected = 'query blocked'
            $result.Actual = "returned '$actual'"
            return [pscustomobject]$result
        }
        $expected = if ($null -ne $case.sql) { Invoke-SqlScalar $case.sql } else { $case.expected }
        $tol = if ($case.tolerance) { [double]$case.tolerance } else { 0 }
        $result.Actual = "$actual"; $result.Expected = "$expected"
        $result.Passed = ($null -ne $actual) -and ([math]::Abs([double]$actual - [double]$expected) -le $tol)
    } catch {
        $msg = $_.Exception.GetBaseException().Message
        if ($case.expectError) {
            $result.Expected = 'query blocked'; $result.Actual = 'blocked'; $result.Passed = $true
        } else {
            $result.Actual = "ERROR: $msg"
        }
    }
    [pscustomobject]$result
}

Initialize-Adomd
$tests = Get-Content $TestFile -Raw | ConvertFrom-Json
$results = @()
$results += $tests.dataValidation | ForEach-Object { Test-Case $_ 'Data validation' }
$results += $tests.security       | ForEach-Object { Test-Case $_ 'RLS/OLS' }

$results | Format-Table -AutoSize | Out-String -Width 250 | Write-Host

if ($env:GITHUB_STEP_SUMMARY) {
    $md = @("### Model tests ($SemanticModelName @ $WorkspaceName, source schema ``$SqlSchema``)", '',
            '| Result | Category | Check | Role | Expected | Actual |', '|---|---|---|---|---|---|')
    foreach ($r in $results) {
        $icon = if ($r.Passed) { 'PASS' } else { 'FAIL' }
        $md += "| $icon | $($r.Category) | $($r.Name) | $($r.Role) | $($r.Expected) | $($r.Actual) |"
    }
    Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value ($md -join "`n")
}

$failed = @($results | Where-Object { -not $_.Passed })
if ($failed.Count -gt 0) {
    Write-Host "::error::$($failed.Count) model test(s) failed"
    exit 1
}
Write-Host "All $($results.Count) model tests passed."
