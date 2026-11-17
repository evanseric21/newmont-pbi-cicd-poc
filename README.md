# Newmont Power BI CI/CD

Version-controlled Power BI reports and semantic models (PBIP/TMDL), promoted through Dev, QA, and Production with GitHub Actions and `fabric-cicd`. Each deployment publishes the model and report, binds the shared gateway connection, performs a full refresh, and runs model-quality, data-reconciliation, and RLS/OLS checks.

## Repository layout

```text
src/
  NewmontProduction.pbip             Power BI Desktop project
  NewmontProduction.SemanticModel/   TMDL model, measures, parameters, RLS/OLS roles
  NewmontProduction.Report/          Report definition
  parameter.yml                     DEV/QA/PROD deployment parameter replacements
.github/
  workflows/                        Validation, release, and rollback workflows
  CODEOWNERS                        Peer review ownership
  pull_request_template.md          Change checklist and UAT evidence
scripts/
  deploy.py                         Publish SemanticModel and Report items
  bind_and_refresh.py               Bind gateway and wait for full refresh
  pbi_common.py                     Shared authentication and REST helpers
  requirements.txt                  Python dependencies
  Invoke-BestPracticeAnalyzer.ps1    Tabular Editor model-quality checks
  Invoke-ModelTests.ps1              Source reconciliation and RLS/OLS assertions
bpa/BPARules.json                    Best Practice Analyzer rules
tests/model-tests.json              Data and security test cases
.gitignore                          Local caches, environments, and secrets exclusions
README.md                           Repository operating guide
```

## Change, approval, and release flow

1. Create a feature branch, edit the PBIP project in Power BI Desktop, and update model tests when totals or security rules change.
2. Open a non-draft PR to `main`. Same-repository PRs deploy to the shared Dev workspace and run all checks; deployments are serialized. Fork and draft PRs are not deployed and cannot pass `Dev gate`.
3. Test in Dev, complete the PR checklist, and attach a screenshot/file URL or sign-off link under `## UAT evidence`. Obtain peer review before merging.
4. Merges affecting `src/`, `tests/`, `bpa/`, `scripts/`, or workflows trigger QA deployment and validation. Successful QA proceeds to the `production` environment's Product Owner approval gate, then Production deployment and validation. The release workflow can also be started manually.
5. Successful Production deployment creates an annotated `release-<UTC timestamp>-run<run number>` tag. If Production fails after publishing and the workflow exposes `published=true`, automatic rollback selects the most recent `release-*` tag and redeploys it with the same checks. A prior release tag must exist.

For manual rollback, run **Rollback Prod** with an existing `release-*` tag. Leaving the tag empty selects the second-most-recent release by tag creation date. Manual rollback uses the `production` approval gate; automatic rollback uses `production-rollback`.

## Workflows

| Workflow | Purpose |
|---|---|
| `pr-validation.yml` | Deploy eligible PRs to Dev and report the required `Dev gate` result. |
| `pr-uat-evidence.yml` | Check the PR body for a UAT evidence URL and the checked Dev-testing declaration; does not execute PR code. |
| `release.yml` | Deploy QA, then Production, tag successful releases, and attempt automatic rollback after a post-publish Production failure. |
| `rollback.yml` | Resolve a selected release tag and redeploy Production after approval. |
| `_deploy-and-validate.yml` | Reusable publish, gateway binding, refresh, BPA, and model-test job for each environment. |

## Required GitHub configuration

Branch protection for `main` should require PR peer approval, code-owner review, and successful `Dev gate` and `UAT evidence` checks. Maintain the reviewer list in `.github/CODEOWNERS`. These governance settings are managed in GitHub, not enforced by the ownership file alone.

Use the following GitHub environments:

| Environment | `FABRIC_ENV` | Target and approval |
|---|---|---|
| `dev` | `DEV` | Dev workspace |
| `qa` | `QA` | QA workspace |
| `production` | `PROD` | Production workspace; required Product Owner reviewer |
| `production-rollback` | `PROD` | Same workspace, source, and credentials as Production; no approval wait for automatic recovery |

The GitHub plan and repository visibility must support environment required reviewers. Restrict changes to deployment code and workflows through trusted review: same-repository PR code runs on the self-hosted runner.

Deployment jobs need the following secrets, scoped at repository or environment level as appropriate:

| Secret | Purpose |
|---|---|
| `AZURE_TENANT_ID` | Service principal tenant ID |
| `AZURE_CLIENT_ID` | Service principal application ID |
| `AZURE_CLIENT_SECRET` | Service principal credential |
| `SQL_READER_USER` | Read-only source account for reconciliation tests |
| `SQL_READER_PASSWORD` | Source account password |

Set these variables on each environment:

| Variable | Purpose |
|---|---|
| `FABRIC_ENV` | Parameter replacement key: `DEV`, `QA`, or `PROD` |
| `WORKSPACE_ID` | Target Fabric/Power BI workspace ID |
| `WORKSPACE_NAME` | Workspace name used by XMLA checks |
| `SEMANTIC_MODEL_NAME` | Deployed model name; defaults to `NewmontProduction` |
| `GATEWAY_ID` | Shared gateway cluster ID |
| `CONNECTION_ID` | Gateway data source connection ID for the environment |
| `SQL_SERVER` | Source server hostname for reconciliation tests |
| `SQL_DATABASE` | Source database for reconciliation tests |
| `SQL_SCHEMA` | Source schema for reconciliation tests |

Keep the model's source parameters in `src/NewmontProduction.SemanticModel/definition/expressions.tmdl`, replacements in `src/parameter.yml`, gateway connection, and test variables aligned. Currently Dev/QA use `newmont_test`, Production uses `newmont_prod`, and all use schema `gold`. The workflows do not inject the `SQL_*` variables into the model definition.

The workflows use the built-in `GITHUB_TOKEN` with read access to repository contents; the release-tag job requests write access. No separate token secret is referenced.

## Runner and platform prerequisites

- An existing self-hosted Windows runner labeled `self-hosted`, `windows`, and `pbi`, with Git, Windows PowerShell 5.1, and Python supporting the packages in `scripts/requirements.txt`. The workflow creates `.venv` and installs those packages.
- Tabular Editor 2 at `C:\tools\TabularEditor\TabularEditor.exe`, or a runner-level `TABULAR_EDITOR_PATH` pointing to the executable; required XMLA/MSOLAP client components must be available.
- ADOMD.NET for .NET Framework under `C:\tools\adomd`, or a runner-level `ADOMD_PATH`. The model-test script downloads the package from NuGet if absent, so that location must be writable and NuGet reachable.
- Network access from the runner to GitHub Actions, Python package sources, Fabric/Power BI APIs and XMLA endpoints, and the SQL source on TCP 1433.
- Existing Dev, QA, and Production workspaces on capacity supporting the required XMLA and refresh operations; XMLA read/write enabled, service principal API access permitted by tenant settings, and workspace permissions sufficient to publish, bind, refresh, and query the model.
- An existing, online gateway with the required source connections and stored source credentials, accessible to the deployment identity. Gateway connectivity and runner-to-source access are separate prerequisites.

Deployment summaries and check results are available on each GitHub Actions run. Never commit credentials or local configuration; `.gitignore` excludes `*.local.json` and `.env`.
