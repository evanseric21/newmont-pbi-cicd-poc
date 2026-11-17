<#
.SYNOPSIS
  Model-quality gate: runs Tabular Editor 2 Best Practice Analyzer against the deployed model over XMLA.
  Severity 3 rule violations fail the pipeline; severity 1-2 are reported as warnings.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkspaceName,
    [Parameter(Mandatory)] [string] $SemanticModelName,
    [string] $RulesFile = (Join-Path $PSScriptRoot '..\bpa\BPARules.json'),
    [string] $TabularEditorPath = $(if ($env:TABULAR_EDITOR_PATH) { $env:TABULAR_EDITOR_PATH } else { 'C:\tools\TabularEditor\TabularEditor.exe' })
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $TabularEditorPath)) { throw "Tabular Editor 2 not found at $TabularEditorPath. Install Tabular Editor 2 on the runner or set TABULAR_EDITOR_PATH to its executable." }

$server = "Provider=MSOLAP;Data Source=powerbi://api.powerbi.com/v1.0/myorg/$WorkspaceName;" +
          "User ID=app:$($env:AZURE_CLIENT_ID)@$($env:AZURE_TENANT_ID);Password=$($env:AZURE_CLIENT_SECRET)"
$rules = (Resolve-Path $RulesFile).Path

# -A <rules> : run BPA with the given rule file; -V : emit Azure DevOps/GitHub-style ##vso logging,
# which makes severity-3 violations errors and returns a non-zero exit code.
$argLine = "`"$server`" `"$SemanticModelName`" -A `"$rules`" -V"
$p = Start-Process -FilePath $TabularEditorPath -ArgumentList $argLine -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput "$env:TEMP\bpa.out" -RedirectStandardError "$env:TEMP\bpa.err"
$out = Get-Content "$env:TEMP\bpa.out" -Raw
$err = Get-Content "$env:TEMP\bpa.err" -Raw
# Never echo the connection string (contains the secret).
$safe = ($out + "`n" + $err).Replace($env:AZURE_CLIENT_SECRET, '***')
Write-Host $safe

$violations = @($safe -split "`n" | Where-Object { $_ -match 'violates rule' })
if ($env:GITHUB_STEP_SUMMARY) {
    $md = @("### Model quality (Best Practice Analyzer)", '', "- Exit code: $($p.ExitCode)", "- Violations: $($violations.Count)")
    $md += $violations | ForEach-Object { "  - $($_.Trim() -replace '^##vso\[[^\]]*\]', '')" }
    Add-Content $env:GITHUB_STEP_SUMMARY ($md -join "`n")
}
Remove-Item "$env:TEMP\bpa.out","$env:TEMP\bpa.err" -ErrorAction SilentlyContinue
$errors = @($violations | Where-Object { $_ -match 'type=error' })
if ($p.ExitCode -ne 0 -or $errors.Count -gt 0) {
    Write-Host "::error::Best Practice Analyzer found $($errors.Count) blocking violation(s) (exit code $($p.ExitCode))"
    exit 1
}
Write-Host "Best Practice Analyzer passed ($($violations.Count) non-blocking warning(s))."
