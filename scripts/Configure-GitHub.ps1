<#
.SYNOPSIS
  Configures the GitHub repo for the POC governance model (run from your workstation with gh CLI authenticated
  as a repo admin).

  * Environments  dev (any branch), qa (main only), production (main + release tags, Product Owner approval,
                  no self-approval), production-rollback (main only, used by automatic rollback)
  * Variables     per-environment FABRIC_ENV / WORKSPACE_* / SQL_DATABASE / CONNECTION_ID,
                  repo-level gateway, SQL server and schema
  * Secrets       service principal + SQL reader (prompted, never written to disk)
  * Branch rules  main: PR required, 1 approval, code-owner review, stale approvals dismissed,
                  required checks "UAT evidence" and "Dev gate"
  * Fork safety   all outside contributors need approval before workflows run; default token read-only

.EXAMPLE
  ./scripts/Configure-GitHub.ps1 -Repo evanseric21/newmont-pbi-cicd-poc -ProductOwners ericevans_microsoft `
     -Config ./poc-config.local.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Repo,
    [Parameter(Mandatory)] [string[]] $ProductOwners,
    [Parameter(Mandatory)] [string] $Config,
    [switch] $SkipSecrets
)
$ErrorActionPreference = 'Stop'
$cfg = Get-Content $Config -Raw | ConvertFrom-Json

function Invoke-GhApi([string] $Method, [string] $Path, $Body) {
    if ($Body) {
        $json = $Body | ConvertTo-Json -Depth 10 -Compress
        $json | gh api -X $Method $Path --input - | Out-Null
    } else {
        gh api -X $Method $Path | Out-Null
    }
    if ($LASTEXITCODE) { throw "gh api $Method $Path failed" }
}

# --- Environments ---
$poReviewers = foreach ($u in $ProductOwners) { @{ type = 'User'; id = [int](gh api "users/$u" --jq .id) } }

Invoke-GhApi PUT "repos/$Repo/environments/dev" @{}
Invoke-GhApi PUT "repos/$Repo/environments/qa" @{ deployment_branch_policy = @{ protected_branches = $false; custom_branch_policies = $true } }
Invoke-GhApi PUT "repos/$Repo/environments/production" @{
    reviewers = @($poReviewers); prevent_self_review = $true
    deployment_branch_policy = @{ protected_branches = $false; custom_branch_policies = $true }
}
Invoke-GhApi PUT "repos/$Repo/environments/production-rollback" @{ deployment_branch_policy = @{ protected_branches = $false; custom_branch_policies = $true } }

foreach ($envName in 'qa','production','production-rollback') {
    $existing = gh api "repos/$Repo/environments/$envName/deployment-branch-policies" --jq '.branch_policies[].name'
    if ($existing -notcontains 'main') { Invoke-GhApi POST "repos/$Repo/environments/$envName/deployment-branch-policies" @{ name = 'main'; type = 'branch' } }
}
# Manual rollback runs from main but deploys a release-* tag ref via checkout, so main is sufficient.

# --- Variables ---
$repoVars = @{
    SEMANTIC_MODEL_NAME = 'NewmontProduction'
    GATEWAY_ID          = $cfg.gatewayId
    SQL_SERVER          = $cfg.sqlServer
    SQL_SCHEMA          = 'gold'
}
foreach ($k in $repoVars.Keys) { gh variable set $k --repo $Repo --body "$($repoVars[$k])" }

# Dev/QA -> test database (Databricks test catalog); Prod -> prod database (Databricks production catalog).
# Each database has its own connection on the shared gateway, so CONNECTION_ID is per environment.
$test = @{ SQL_DATABASE = $cfg.sources.test.database; CONNECTION_ID = $cfg.sources.test.connectionId }
$prod = @{ SQL_DATABASE = $cfg.sources.prod.database; CONNECTION_ID = $cfg.sources.prod.connectionId }
$envVars = @{
    'dev'                 = @{ FABRIC_ENV = 'DEV';  WORKSPACE_ID = $cfg.workspaces.dev.id;  WORKSPACE_NAME = $cfg.workspaces.dev.name } + $test
    'qa'                  = @{ FABRIC_ENV = 'QA';   WORKSPACE_ID = $cfg.workspaces.qa.id;   WORKSPACE_NAME = $cfg.workspaces.qa.name } + $test
    'production'          = @{ FABRIC_ENV = 'PROD'; WORKSPACE_ID = $cfg.workspaces.prod.id; WORKSPACE_NAME = $cfg.workspaces.prod.name } + $prod
    'production-rollback' = @{ FABRIC_ENV = 'PROD'; WORKSPACE_ID = $cfg.workspaces.prod.id; WORKSPACE_NAME = $cfg.workspaces.prod.name } + $prod
}
foreach ($e in $envVars.Keys) {
    foreach ($k in $envVars[$e].Keys) { gh variable set $k --repo $Repo --env $e --body "$($envVars[$e][$k])" }
}

# --- Secrets (repo-level; prompted) ---
if (-not $SkipSecrets) {
    foreach ($s in 'AZURE_TENANT_ID','AZURE_CLIENT_ID','AZURE_CLIENT_SECRET','SQL_READER_USER','SQL_READER_PASSWORD') {
        $sec = Read-Host -AsSecureString "Value for $s"
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
        $plain | gh secret set $s --repo $Repo
    }
}

# --- Actions hardening for a public repo with a self-hosted runner ---
Invoke-GhApi PUT "repos/$Repo/actions/permissions/workflow" @{ default_workflow_permissions = 'read'; can_approve_pull_request_reviews = $false }
Invoke-GhApi PUT "repos/$Repo/actions/permissions/fork-pr-contributor-approval" @{ approval_policy = 'all_external_contributors' }

# --- Branch protection on main ---
Invoke-GhApi PUT "repos/$Repo/branches/main/protection" @{
    required_status_checks        = @{ strict = $true; contexts = @('UAT evidence', 'Dev gate') }
    enforce_admins                = $false
    required_pull_request_reviews = @{ required_approving_review_count = 1; require_code_owner_reviews = $true; dismiss_stale_reviews = $true; require_last_push_approval = $true }
    restrictions                  = $null
    allow_force_pushes            = $false
    allow_deletions               = $false
}

# --- Protect release tags (the rollback targets) from deletion/rewrite ---
$rules = gh api "repos/$Repo/rulesets" --jq '.[].name'
if ($rules -notcontains 'protect-release-tags') {
    Invoke-GhApi POST "repos/$Repo/rulesets" @{
        name = 'protect-release-tags'; target = 'tag'; enforcement = 'active'
        conditions = @{ ref_name = @{ include = @('refs/tags/release-*'); exclude = @() } }
        rules = @(@{ type = 'deletion' }, @{ type = 'non_fast_forward' }, @{ type = 'update' })
    }
}

Write-Host "GitHub configuration complete for $Repo"
