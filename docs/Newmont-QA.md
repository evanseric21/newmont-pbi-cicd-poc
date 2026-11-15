# Newmont Power BI CI/CD – Answers, Feasibility and Open Questions

**Prepared for:** Newmont BI team (Gary et al.)  
**Prepared by:** Eric Evans  
**Purpose:** Explains how each item in the agreed POC scope is met, what is fully supported, what has caveats, and what we need from Newmont to replicate the setup.

Legend: ✅ Supported as described · ⚠️ Supported with caveats or a configuration dependency · ❌ Not possible as stated (alternative provided)

---

## 1. Requirement-by-requirement answers

### 1.1 Separate Dev, QA and Prod workspaces ✅
- Each environment is its own Fabric/Power BI workspace. The pipeline deploys the same Git commit to each workspace using the Fabric REST APIs, via Microsoft's open-source **fabric-cicd** library.
- **Needs:** workspaces on Fabric (F SKU) or Premium capacity, which XMLA-based checks require. The deployment service principal must be a workspace **Admin or Member**.
- Power BI *deployment pipelines* are **not** required. GitHub Actions does the promotion, so approvals, history and rollback all live in GitHub. If Newmont already uses deployment pipelines, the two can coexist, but we recommend one source of truth for promotion.

### 1.2 Cloud-hosted GitHub ✅ / ⚠️
- GitHub Actions orchestrates everything. Power BI content is stored as **PBIP** (Power BI Project) with the semantic model in **TMDL**, which gives readable diffs for peer review instead of binary `.pbix` files.
- ⚠️ **Licensing caveat:** *required reviewers* on GitHub environments (used for Product Owner approval) are only available for **private or internal repositories on GitHub Enterprise Cloud**. On Free, Pro and Team plans they only work on public repos. Our POC repo is public for this reason; Newmont's repo should be private or internal on Enterprise.
- ⚠️ Self-hosted runners should **never** be attached to public repositories in production. For Newmont, use a private or internal repo and an org-level **runner group** restricted to that repo.

### 1.3 One shared gateway connection, with catalog/schema parameters per environment ✅ / ⚠️
- The semantic model exposes `CatalogName` and `SchemaName` (Power Query parameters). The pipeline rewrites them per environment at deploy time (`parameter.yml`): Dev and QA point to the test catalog, Prod points to the production catalog. The model is then bound to the **same** gateway connection with the Power BI REST API (`BindToGateway`) and refreshed.
- ✅ This works with one connection **if Databricks test and prod are reached through the same Databricks connection**: the same workspace hostname and the same SQL Warehouse HTTP path, with Unity Catalog separating `test` and `prod` catalogs. A Power BI connection is keyed on *hostname + HTTP path*. Catalog and schema are query-level, so they can vary per environment.
- ⚠️ **If test and production are separate Databricks workspaces or warehouses** (different hostnames or HTTP paths), one connection is **not possible**. You would need two connections (both can live on the same gateway cluster) and the pipeline would bind each environment to its own connection ID. This is a one-line pipeline variable change.
- ⚠️ The credential on the shared connection applies to every environment. If Prod must use a different Databricks identity than Test (common for segregation of duties), use separate connections.
- ⚠️ A gateway is only needed if Databricks is not publicly reachable (Private Link or no public access). Otherwise a cloud connection without a gateway is simpler. Please confirm which applies.
- **Service principal needs:** the deployment SP must be added as a **User** on the gateway connection, or it can't bind models to it.
- POC note: we simulate Databricks with an Azure SQL database containing `test_gold` and `prod_gold` schemas behind one gateway connection. The parameter-swap mechanism is identical.

### 1.4 Roles and approvals ✅
| Control | Implementation | Enforced by |
|---|---|---|
| Peer developer review | PR to `main` requires 1 approval from CODEOWNERS (not the author). New pushes dismiss stale approvals | GitHub branch protection |
| Developer testing with UAT evidence attached | Every PR is deployed to **Dev** automatically. The PR template has a required *UAT evidence* section, and a status check blocks merge until it contains an attachment or link and the "tested in Dev" box is ticked | GitHub Actions check + branch protection |
| Product Owner approval and deployment | After merge, QA deploys automatically. The Prod job pauses on the `production` environment until a Product Owner approves; self-approval is blocked. Approval triggers the deployment, so the PO does not need workspace permissions | GitHub environment protection rules |
- ⚠️ The UAT check can enforce that evidence is **present**, not that it is **adequate**. Judging the evidence remains the reviewer's and PO's responsibility.
- Every approval (who, when, comments) is recorded in GitHub and visible in the deployment history, which gives an audit trail.

### 1.5 Promotion checks ✅ / ⚠️
Every environment (Dev on PR, QA on merge, Prod after approval) runs the same gates. Any failure stops promotion.

| Check | How | Notes |
|---|---|---|
| **Model quality** | Tabular Editor 2 *Best Practice Analyzer* over XMLA with a version-controlled rules file (`bpa/BPARules.json`). Severity-3 violations fail the build | Rules are customizable. We include format strings, hidden FKs, no floating point, parameterized sources, and roles defined |
| **Successful refresh in target environment** | Bind to the gateway connection, then trigger an enhanced (REST) full refresh and poll until it completes | ⚠️ The pipeline waits for the refresh, so large models make deployments longer. Agree a timeout or use incremental refresh |
| **Data validation (key totals, row counts)** | DAX queries against the refreshed model are compared to SQL against the source (`tests/model-tests.json`) | ⚠️ For Databricks, the runner needs a Databricks SQL Warehouse connection (ODBC/JDBC or the SQL Statement API) and a read-only identity. Newmont needs to supply the list of "key totals" |
| **RLS verification** | DAX run over XMLA as a specific role (`Roles=<role>`). The test asserts that only the permitted rows are returned | ⚠️ **Dynamic RLS** (`USERPRINCIPALNAME()`) also needs `EffectiveUserName=<real UPN>` test accounts in the tenant |
| **OLS verification** | DAX referencing a secured column, run as the restricted role. The test asserts the query is blocked | ⚠️ OLS cannot be authored in the Power BI Desktop UI. Use the TMDL view or Tabular Editor. Desktop *View as* still honors OLS for testing |
- **Requirement:** XMLA endpoint set to **Read Write** on the capacity, and the SP must be a workspace Admin or Member.

### 1.6 Rollback ✅ / ⚠️
- Every successful Prod deployment is tagged in Git (`release-YYYYMMDD-HHMMSS-runN`). Tags are protected against deletion and rewrite.
- **Automatic:** if any Prod check fails *after* publishing, the pipeline redeploys the previous `release-*` tag and re-runs the checks.
- **Manual:** the "Rollback Prod" workflow redeploys any chosen tag (the default is the version before the latest). It requires Product Owner approval.
- ⚠️ Rollback restores the **definition** (model, measures, RLS/OLS, report), not the **data**. The rolled-back model is refreshed again from the source. If source data caused the failure, rollback won't fix it.
- ⚠️ If a deployment changes the model schema (for example, removes a table), Prod may show empty or failed visuals until the post-deploy refresh completes. Schedule Prod deployments in a maintenance window, or we can evaluate XMLA-based metadata deployment that preserves data for unchanged tables. **(Will be validated during the POC.)**

---

## 2. Self-hosted runners – why and what's needed
- **Why:** model quality, RLS/OLS and data-validation checks use Tabular Editor 2 and ADOMD.NET, which require Windows. The runner also needs network access to Databricks for source reconciliation. If Databricks is private, GitHub-hosted runners can't reach it.
- **POC:** one Azure Windows Server 2022 VM hosts both the runner (label `pbi`) and the on-premises data gateway.
- **Newmont recommendation:** a dedicated runner VM, or a small autoscaled pool, inside the network that can reach Databricks. The gateway should be on **separate** machines in a 2-node cluster for high availability. Register the runner at org level in a runner group limited to the Power BI repo.
- **Runner software:** Git, Python 3.12, Tabular Editor 2 (free, portable) and ADOMD.NET. Power BI Desktop is **not** needed on the runner.

## 3. Power BI Desktop and the developer experience
- Developers keep working in Power BI Desktop but save as **PBIP** with **TMDL**. Check your Desktop version: some versions still list these under Preview features.
- The flow is: branch → edit in Desktop → commit → PR. Publishing from Desktop to Dev is optional for quick iteration, but **Git is the source of truth**, and Dev is overwritten by each PR deployment.
- Only one PR can own the shared Dev workspace at a time; the pipeline serializes them. If several developers work in parallel, consider per-developer workspaces or Fabric Git integration for personal workspaces.

## 4. Things that are not possible, or not possible as stated
| Ask / assumption | Status | Alternative |
|---|---|---|
| Run Power BI Desktop or its refresh inside the pipeline | ❌ Desktop is interactive only | All tests run in the Fabric service over REST and XMLA after deployment |
| One gateway connection when Test and Prod are different Databricks workspaces or warehouses | ❌ | One connection per Databricks endpoint on the same gateway cluster. The pipeline binds by environment |
| PO approval gates on a private repo without GitHub Enterprise | ❌ | GitHub Enterprise Cloud (recommended), or a manual approval workflow (weaker control) |
| Author OLS in Desktop UI | ❌ | TMDL view or Tabular Editor. The pipeline verifies it |
| Rollback of data, not just definitions | ❌ (by design) | Re-refresh from source. Use Delta time travel in Databricks if historic data must be restored |
| Validate visual rendering of reports | ⚠️ Not in POC scope | Report-level rule checks (for example, PBI Inspector) can be added later |

## 5. Licensing and tenant prerequisites
- Fabric capacity (F SKU) or Power BI Premium for Dev, QA and Prod (XMLA Read Write). Viewers need Pro unless the capacity is F64 or larger.
- Tenant settings: *Service principals can use Fabric APIs* (scoped to a security group), plus XMLA Read Write on the capacity.
- An Entra ID app registration (service principal) with a client secret or certificate. A certificate or **workload identity federation (OIDC)** is recommended so no secret is stored in GitHub.
- GitHub Enterprise Cloud for private repos with environment approvals and runner groups.

## 6. Open questions for Newmont
1. Are Databricks **test and production** in the **same** Databricks workspace or SQL Warehouse (different catalogs), or separate workspaces? This decides whether one gateway connection is possible.
2. Is a gateway required, meaning Databricks Private Link or no public access? Or could a cloud connection be used?
3. Which credential type does the gateway connection use for Databricks (PAT, OAuth/Entra, or a Databricks service principal)? Is the same identity acceptable for Test and Prod?
4. What GitHub plan does Newmont have (Enterprise Cloud?), and does an org-level runner group exist?
5. Is RLS **static** (role-based) or **dynamic** (`USERPRINCIPALNAME()`)? If dynamic, can we get test UPNs for automated RLS checks?
6. Which **key totals and row counts** define "data validated" for the first model? (For example, ounces produced, tonnes milled, AISC by site and month.)
7. Who are the **Product Owners** (GitHub users or teams) and peer reviewers for each model?
8. Is there a required deployment window for Prod, given the post-deploy refresh?
9. Are Power BI deployment pipelines or Fabric Git integration in use today, and should they be retained?
10. Model size and refresh duration for the first model in scope (this sets pipeline timeouts).
11. Could you share the scoping call notes or transcript?
