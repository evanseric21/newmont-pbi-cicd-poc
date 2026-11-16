# Guided Walkthrough – Newmont Power BI CI/CD POC

Follow the phases in order. Every phase ends with a **Checkpoint**: don't move on until every box is ticked.
`docs/Setup-Guide.md` has the full command reference. This file is the order of work and the checks that prove each step worked.

**Where it all lives:** your existing **demo tenant**. You don't need a separate POC tenant. The POC is isolated by:
- the resource group `rg-newmont-pbi-poc` (Fabric capacity, SQL, VM)
- three dedicated workspaces
- a dedicated service principal and security group
- its own gateway and connections

Record every ID you collect in `poc-config.local.json` (copy of `poc-config.sample.json`, git-ignored).

| Phase | What | Time |
|---|---|---|
| 0 | Workstation tools | 15 min |
| 1 | Demo tenant + Azure subscription alignment | 15 min |
| 2 | Fabric capacity | 20 min |
| 3 | Service principal, security group, tenant settings | 30 min |
| 4 | Azure infra (SQL + VM) and sample data | 45 min |
| 5 | Fabric workspaces | 15 min |
| 6 | Gateway + connections (on the VM) | 30 min |
| 7 | Self-hosted runner (on the VM) | 30 min |
| 8 | GitHub governance | 20 min |
| 9 | Report in Power BI Desktop | 30 min |
| 10 | End-to-end dry runs | 1–2 h |

---

## Phase 0 – Workstation tools
1. Repair the Azure CLI. A broken `automation` extension makes every `az` command fail with *Access is denied*:
   ```powershell
   Remove-Item -Recurse -Force "$env:USERPROFILE\.azure\cliextensions\automation"
   az version
   ```
   If `Remove-Item` is denied, close any other terminals or VS Code windows that are using `az`, then retry.
2. Make sure `gh`, `sqlcmd`, `git`, Python 3.12 or later, and Power BI Desktop (current release) are installed. On your machine, all of these were already present.
3. Clone the repo: `gh repo clone evanseric21/newmont-pbi-cicd-poc`

**Checkpoint 0**
- [ ] `az version` runs without errors
- [ ] `gh auth status` shows `evanseric21`
- [ ] The repo is cloned locally

## Phase 1 – Demo tenant and Azure subscription alignment
Fabric, Entra ID and the Azure subscription that pays for the capacity **must be in the same tenant**.
1. Browse to https://app.fabric.microsoft.com and sign in with your **demo tenant admin** account. Select **?** (Help) → **About** and note the **Tenant URL / ID**.
2. Sign the CLI in to that tenant and select the paid subscription:
   ```powershell
   az login --tenant <demo-tenant-id>
   az account list --query "[].{name:name, id:id, tenant:tenantId}" -o table
   az account set --subscription <subscription-id>
   az account show --query "{tenant:tenantId, sub:name, user:user.name}"
   ```
3. Make sure you hold these roles: **Fabric Administrator** (or Global Administrator) in the tenant, and **Owner** or **Contributor + User Access Administrator** on the subscription. To check, open Entra ID → Roles and administrators, and Subscription → Access control.

> If the paid subscription lives in a **different** tenant (for example, your corporate tenant), stop and tell me. Either use a Fabric trial for the capacity, or have the subscription made available in the demo tenant.

**Checkpoint 1**
- [ ] The Fabric tenant ID matches the `tenant` value from `az account show`
- [ ] You can open **Admin portal** in Fabric (Settings ⚙ → Admin portal)
- [ ] You can create resource groups in the subscription

## Phase 2 – Fabric capacity
**Recommended:** a paid **F2** capacity in your subscription. It costs about $0.36 an hour, is pausable, and you control it.
**Alternative:** the 60-day Fabric trial (Account manager → *Start trial*).
1. Create the resource group and capacity:
   ```powershell
   az group create -n rg-newmont-pbi-poc -l eastus2
   ```
   In the Azure portal, search **Microsoft Fabric** → **Create**:
   - Resource group: `rg-newmont-pbi-poc`
   - Name: `newmontpocfabric`
   - Region: the same as your Fabric home region if possible
   - Size: **F2**
   - Fabric capacity administrator: your demo admin account
2. In Fabric → Admin portal → **Capacity settings** → *Fabric capacity* → `newmontpocfabric`:
   - **Power BI workloads → XMLA Endpoint = Read Write**

> Pause the capacity when you're not working on it (Azure portal → capacity → **Pause**). Workspaces become read-only while it's paused.

**Checkpoint 2**
- [ ] The capacity shows **Active** in Admin portal → Capacity settings
- [ ] XMLA Endpoint is set to **Read Write**

## Phase 3 – Service principal, security group, tenant settings
1. In Entra ID → App registrations → **New registration**, create `sp-newmont-pbi-cicd-poc` as a single tenant app. Then go to **Certificates & secrets** → New client secret and copy the value now. Record the **Application (client) ID** and **Tenant ID**.
   - Don't add any Power BI API permissions. Access comes from the tenant setting and workspace roles below.
2. In Entra ID → Groups, create a **Security** group `sg-pbi-cicd-sp` and add the app's service principal as a member.
3. In Fabric Admin portal → **Tenant settings**, enable these, scoped to `sg-pbi-cicd-sp` (*Specific security groups*):
   - **Developer settings → Service principals can use Fabric APIs**
   - **Integration settings → Allow XMLA endpoints and Analyze in Excel with on-premises semantic models** (enabled)
4. Allow up to 15 minutes for the settings to take effect.

**Checkpoint 3**
- [ ] The SP can get a token. Run this on the workstation:
  ```powershell
  az login --service-principal -u <client-id> -p <secret> --tenant <tenant-id> --allow-no-subscriptions
  az account get-access-token --resource https://analysis.windows.net/powerbi/api --query expiresOn
  az login --tenant <demo-tenant-id>   # switch back to your user
  ```
- [ ] Both tenant settings show **Enabled for: sg-pbi-cicd-sp**

## Phase 4 – Azure infrastructure and sample data
1. Find your workstation's public IP with `(Invoke-RestMethod https://api.ipify.org)`. Put it in `infra/main.bicepparam` → `allowedClientCidr = '<ip>/32'`.
2. Deploy:
   ```powershell
   $env:POC_SQL_ADMIN_PASSWORD = '<strong password>'
   $env:POC_VM_ADMIN_PASSWORD  = '<strong password>'
   az deployment group create -g rg-newmont-pbi-poc -f infra/main.bicep -p infra/main.bicepparam --query properties.outputs
   ```
   Record `sqlServerFqdn`, `vmName` and `vmPublicIp`.
3. Seed **both** databases (Dev/QA test catalog = 1.0, Prod catalog = 1.5):
   ```powershell
   sqlcmd -S <sqlServerFqdn> -d newmont_test -U sqladminpoc -P $env:POC_SQL_ADMIN_PASSWORD -i sql/seed.sql -v Multiplier="1.0" ReaderUser="pbi_reader" ReaderPassword="<reader password>"
   sqlcmd -S <sqlServerFqdn> -d newmont_prod -U sqladminpoc -P $env:POC_SQL_ADMIN_PASSWORD -i sql/seed.sql -v Multiplier="1.5" ReaderUser="pbi_reader" ReaderPassword="<reader password>"
   ```
4. Put your `sqlServerFqdn` in `src/NewmontProduction.SemanticModel/definition/expressions.tmdl` → `SqlServer` and in `poc-config.local.json`.

**Checkpoint 4**
- [ ] Both seed runs end with **72** fact rows. Prod GoldOunces = 1.5 × test
- [ ] The reader login works: `sqlcmd -S <fqdn> -d newmont_prod -U pbi_reader -P <pwd> -Q "SELECT COUNT(*) FROM gold.DimSite"` returns **6**
- [ ] You can RDP to `vmPublicIp`

## Phase 5 – Fabric workspaces
1. Create `Newmont POC - Dev`, `Newmont POC - QA` and `Newmont POC - Prod`. For each: Workspace settings → **License info** → Fabric capacity `newmontpocfabric`.
2. For each, go to **Manage access** → add `sg-pbi-cicd-sp` (or the SP) as **Admin**. Add your second account (`ericevans_microsoft`) as Viewer on Prod if you want the PO to see results.
3. Record each workspace ID (the GUID after `/groups/` in the URL) in `poc-config.local.json`.

**Checkpoint 5**
- [ ] Each workspace shows the diamond (capacity) icon
- [ ] The SP is **Admin** on all three
- [ ] The XMLA address works: Workspace settings → License info → **Connection link** shows `powerbi://api.powerbi.com/v1.0/myorg/Newmont POC - Dev`

## Phase 6 – On-premises data gateway (on the VM)
1. RDP to the VM. Install the **standard** gateway from https://aka.ms/opdg. Sign in with your demo admin account and register a gateway named `gw-newmont-poc`. Save the recovery key somewhere safe.
2. In the Fabric service → Settings ⚙ → **Manage connections and gateways** → **New** → *On-premises*, create two connections on `gw-newmont-poc`:

   | Name | Type | Server | Database | Auth |
   |---|---|---|---|---|
   | `newmont-poc-sql-test` | SQL Server | `<sqlServerFqdn>` | `newmont_test` | Basic, `pbi_reader` |
   | `newmont-poc-sql-prod` | SQL Server | `<sqlServerFqdn>` | `newmont_prod` | Basic, `pbi_reader` |

   Privacy level for both: Organizational.
3. On each connection, go to **Manage users** → add `sp-newmont-pbi-cicd-poc` as **User**.
4. Record the gateway cluster ID and both connection IDs (from each connection's **Settings** pane) in `poc-config.local.json` → `gatewayId`, `sources.test.connectionId` and `sources.prod.connectionId`.

**Checkpoint 6**
- [ ] The gateway shows **Online** in Manage connections and gateways
- [ ] Both connections test successfully (**Status: Online** after saving)
- [ ] The SP is listed as a User on both connections

## Phase 7 – Self-hosted runner (on the VM)
1. On your workstation, get a token. It expires after 1 hour:
   `gh api -X POST repos/evanseric21/newmont-pbi-cicd-poc/actions/runners/registration-token --jq .token`
2. On the VM, copy `scripts/Setup-RunnerVm.ps1` over, then in an elevated Windows PowerShell run:
   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass
   .\Setup-RunnerVm.ps1 -RepoUrl https://github.com/evanseric21/newmont-pbi-cicd-poc -RunnerToken <token>
   Get-Service actions.runner.* | Restart-Service
   ```

**Checkpoint 7**
- [ ] `gh api repos/evanseric21/newmont-pbi-cicd-poc/actions/runners --jq '.runners[] | [.name,.status,(.labels|map(.name)|join(","))]'` shows **online** with the label `pbi`
- [ ] On the VM, `python --version`, `git --version` and `$env:TABULAR_EDITOR_PATH` all resolve in a new shell

## Phase 8 – GitHub governance
1. Invite the peer reviewer / PO account:
   `gh api -X PUT repos/evanseric21/newmont-pbi-cicd-poc/collaborators/ericevans_microsoft -f permission=push`
   Then accept the invite while signed in as `ericevans_microsoft`.
2. Run (it prompts for the SP and SQL reader secrets):
   ```powershell
   ./scripts/Configure-GitHub.ps1 -Repo evanseric21/newmont-pbi-cicd-poc -ProductOwners ericevans_microsoft -Config ./poc-config.local.json
   ```

**Checkpoint 8**
- [ ] `gh api repos/evanseric21/newmont-pbi-cicd-poc/environments --jq '.environments[].name'` lists dev, qa, production and production-rollback
- [ ] `gh variable list --repo evanseric21/newmont-pbi-cicd-poc --env production` shows `SQL_DATABASE=newmont_prod` and the prod `CONNECTION_ID`
- [ ] `gh secret list --repo evanseric21/newmont-pbi-cicd-poc` shows 5 secrets
- [ ] Settings → Branches shows `main` protected, with the required checks **UAT evidence** and **Dev gate**

## Phase 9 – Report in Power BI Desktop
1. Open `src/NewmontProduction.pbip`. Select **Refresh**, and when prompted, enter the `pbi_reader` credentials (Database auth).
2. Add these visuals to *Production Overview*:
   - a card (Total Gold Ounces)
   - a bar chart (gold ounces by Region)
   - a line chart (gold ounces by MonthName)
   - a table (SiteName, Total Cost USD, Cost per Ounce)
3. Go to Modeling → **View as** → `North America`, then `Restricted Cost`, and confirm that RLS and OLS behave as expected.
4. Save. Then create a branch, commit and push, and open a PR:
   ```powershell
   git switch -c feature/initial-report; git add -A; git commit -m "Initial report visuals"; git push -u origin HEAD
   gh pr create --fill
   ```

**Checkpoint 9**
- [ ] Desktop shows data, with Total Gold Ounces matching the test seed total
- [ ] The PR is open and the **Dev / Deploy & Validate** job has started on the self-hosted runner

## Phase 10 – End-to-end dry runs
| # | Scenario | Expected |
|---|---|---|
| a | Happy path: PR → Dev → merge → QA → PO approves → Prod | All checks green, `release-*` tag created, Prod totals = 1.5 × QA |
| b | Break a BPA rule (for example, remove a measure's format string) | Dev gate fails, merge blocked |
| c | Remove the UAT screenshot from the PR | `UAT evidence` fails |
| d | Author tries to approve Prod | Blocked (self-review prevented) |
| e | Break RLS (change the `North America` filter) and approve Prod | Prod checks fail, auto-rollback redeploys the previous tag |
| f | Run **Rollback Prod** manually | The chosen tag is redeployed after PO approval |

**Checkpoint 10**
- [ ] All six scenarios behave as expected. Capture screenshots for the Newmont demo.
