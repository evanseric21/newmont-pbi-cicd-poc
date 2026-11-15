# Setup Guide – Newmont Power BI CI/CD POC

> Run these steps in order. Allow about half a day. Values you collect along the way go into `poc-config.local.json` (copy it from `poc-config.sample.json`; it is git-ignored).

## 0. Prerequisites
- Fabric capacity (F SKU) or Fabric trial, and Fabric/Power BI admin rights in the test tenant
- Azure subscription (Contributor on a resource group)
- Power BI Desktop (current release). Enable **Options → Preview features → Power BI Project (.pbip) save option** and **Store semantic model using TMDL format** if your version still lists them as preview
- `az`, `gh` and `sqlcmd` on your workstation
- A second GitHub account to act as peer reviewer and Product Owner (the POC uses `ericevans_microsoft`)

## 1. Service principal and tenant settings
1. Entra ID → App registrations → **New**: `sp-newmont-pbi-cicd-poc`. Create a client secret.
2. Create a security group `sg-pbi-cicd-sp` and add the SP to it.
3. Fabric Admin portal → Tenant settings:
   - *Service principals can use Fabric APIs* → enabled for `sg-pbi-cicd-sp`
   - *Allow service principals to use read-only admin APIs* → optional
4. Admin portal → Capacity settings → your capacity → **XMLA Endpoint = Read Write**.

## 2. Azure infrastructure
```powershell
$env:POC_SQL_ADMIN_PASSWORD = '<strong password>'
$env:POC_VM_ADMIN_PASSWORD  = '<strong password>'
# edit infra/main.bicepparam -> allowedClientCidr = '<your public IP>/32'
az group create -n rg-newmont-pbi-poc -l eastus2
az deployment group create -g rg-newmont-pbi-poc -f infra/main.bicep -p infra/main.bicepparam --query properties.outputs
```
Record `sqlServerFqdn` and `vmPublicIp`.

## 3. Seed the sample data
```powershell
sqlcmd -S <sqlServerFqdn> -d newmont_poc -U sqladminpoc -P $env:POC_SQL_ADMIN_PASSWORD -i sql/seed.sql `
  -v ReaderUser="pbi_reader" ReaderPassword="<reader password>"
```
Expected output: 72 rows in each schema, and prod gold ounces = 1.5 × test.

Update `src/NewmontProduction.SemanticModel/definition/expressions.tmdl` → `SqlServer` with your `sqlServerFqdn` and commit.

## 4. On-premises data gateway (on the VM)
1. RDP to the VM. Download and install the **standard** gateway from https://aka.ms/opdg.
2. Sign in with your Power BI admin account and register a new gateway: `gw-newmont-poc`.
3. Power BI service → Settings → **Manage connections and gateways** → *New* → **On-premises**:
   - Gateway cluster: `gw-newmont-poc` · Connection name: `newmont-poc-sql (shared)`
   - Type: SQL Server · Server: `<sqlServerFqdn>` · Database: `newmont_poc`
   - Authentication: Basic → `pbi_reader` / password · Privacy level: Organizational
4. On the connection → **Manage users** → add the SP (`sp-newmont-pbi-cicd-poc`) as **User**.
5. Record the **gateway cluster ID** and **connection ID** (connection → Settings shows both).

> At Newmont this is the Databricks connection (Server hostname + HTTP path). Only the catalog and schema differ per environment, so one connection serves Dev, QA and Prod.

## 5. Workspaces
Create `Newmont POC - Dev`, `Newmont POC - QA` and `Newmont POC - Prod` on the Fabric capacity. Add `sg-pbi-cicd-sp` (or the SP) as **Admin** to each. Record each workspace ID (from the URL `/groups/<id>/`).

## 6. Self-hosted runner (on the VM)
```powershell
# on your workstation
gh api -X POST repos/evanseric21/newmont-pbi-cicd-poc/actions/runners/registration-token --jq .token
# on the VM (elevated Windows PowerShell)
Set-ExecutionPolicy -Scope Process Bypass
.\Setup-RunnerVm.ps1 -RepoUrl https://github.com/evanseric21/newmont-pbi-cicd-poc -RunnerToken <token>
Get-Service actions.runner.* | Restart-Service
```
Confirm the runner shows as **Idle** under repo Settings → Actions → Runners, with labels `self-hosted, Windows, X64, pbi`.

## 7. GitHub governance
```powershell
gh api -X PUT repos/evanseric21/newmont-pbi-cicd-poc/collaborators/ericevans_microsoft -f permission=push
# accept the invite as ericevans_microsoft, then:
./scripts/Configure-GitHub.ps1 -Repo evanseric21/newmont-pbi-cicd-poc -ProductOwners ericevans_microsoft -Config ./poc-config.local.json
```
You'll be prompted for `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `SQL_READER_USER` and `SQL_READER_PASSWORD`.

## 8. Build the report in Power BI Desktop
1. Open `src/NewmontProduction.pbip`. Refresh, and enter `pbi_reader` credentials when prompted.
2. On *Production Overview*, add: a card (Total Gold Ounces), a clustered bar (gold ounces by Region), a line (gold ounces by MonthName), and a table (SiteName, Total Cost USD, Cost per Ounce).
3. Modeling → **View as** → `North America` to sanity-check RLS, then `Restricted Cost` to check OLS.
4. Save. Commit on a feature branch and open a PR to run the first end-to-end test.

## 9. First run checklist
- [ ] PR: `Dev / Deploy & Validate` green, job summary shows the BPA, refresh and model test tables
- [ ] PR: `UAT evidence` fails until a screenshot is attached, then passes
- [ ] Merge blocked until `ericevans_microsoft` approves
- [ ] QA deploys on merge. Prod waits for PO approval. The author cannot self-approve
- [ ] Prod totals are 1.5 × QA (proves the catalog switch). A `release-*` tag is created
- [ ] Rollback test: run **Rollback Prod** manually and confirm the previous tag is redeployed

## Troubleshooting
| Symptom | Likely cause |
|---|---|
| `401/403` from fabric-cicd | SP not workspace Admin/Member, or the *Service principals can use Fabric APIs* setting is off |
| BindToGateway `DMTS_DatasourceHasNoCredentialError` / not found | SP not added as a user on the connection, or the model's server/database doesn't exactly match the connection |
| XMLA `Could not connect` | XMLA endpoint not set to Read Write on the capacity, or the workspace isn't on the capacity |
| BPA step can't find TabularEditor.exe | Restart the runner service after setup so it picks up `TABULAR_EDITOR_PATH` |
| OLS test passes but RLS returns all rows | Testing with `Roles=` needs the SP to be workspace Admin/Member (it is evaluated as that role, not as the SP) |
