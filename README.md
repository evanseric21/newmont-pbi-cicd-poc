# Newmont Power BI CI/CD POC

End-to-end CI/CD for Power BI (PBIP/TMDL), using GitHub Actions, `fabric-cicd`, a self-hosted Windows runner, and one shared gateway connection with per-environment catalog/schema parameters.

**Flow:** feature branch → PR (Dev deploy, refresh, BPA, data and RLS/OLS tests, UAT evidence, peer review) → merge → QA (same checks) → **Product Owner approval** → Prod (same checks) → `release-*` tag, with auto-rollback to the previous tag on failure.

| Doc | |
|---|---|
| [docs/POC-Plan.md](docs/POC-Plan.md) | Scope, architecture, workstreams, demo script |
| [docs/Setup-Guide.md](docs/Setup-Guide.md) | Step-by-step build of the test environment |
| [docs/Newmont-QA.md](docs/Newmont-QA.md) | Customer-facing answers, feasibility caveats, open questions |

## Repo layout
```
src/
  NewmontProduction.pbip                 open in Power BI Desktop
  NewmontProduction.SemanticModel/       TMDL: tables, measures, RLS + OLS roles, parameters
  NewmontProduction.Report/
  parameter.yml                          per-environment catalog/schema swap (DEV/QA/PROD)
.github/workflows/
  pr-validation.yml                      PR -> Dev deploy + checks ("Dev gate")
  pr-uat-evidence.yml                    blocks merge until UAT evidence attached
  release.yml                            main -> QA -> (PO approval) -> Prod -> tag / auto-rollback
  rollback.yml                           manual redeploy of a release-* tag (PO approval)
  _deploy-and-validate.yml               reusable: publish, bind+refresh, BPA, data + RLS/OLS tests
scripts/                                 deploy.py, bind_and_refresh.py, Invoke-*.ps1, setup scripts
tests/model-tests.json                   data validation + RLS/OLS assertions
bpa/BPARules.json                        model-quality rules
infra/main.bicep                         Azure SQL + runner/gateway VM
sql/seed.sql                             sample data (test_gold / prod_gold)
```

> ⚠️ This repo is public only because GitHub Free needs a public repo for environment required reviewers. It contains fictional sample data and no secrets. Fork PRs never run on the self-hosted runner.
