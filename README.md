# ntis-devops

CI/CD for NTIS. It implements the *Git Branching & Merging Strategy* playbook for three app repos
(`ntis-ui`, `ntis-platform`, `ntis-database-manager`) deployed to multi-tenant IIS hosts.

```
feature/* ──PR──▶ develop ──PR──▶ qa ──PR──▶ staging ──PR──▶ main
   (CI)            (Dev)          (QA)       (Staging)      (Prod, tag vX.Y.Z)
                                              ▲ release/X.Y.Z      ▲ hotfix/*
```

- **A merge deploys.** Each env branch maps to an environment (`config/environments.json`). A push to it
  dispatches `deploy-env.yml`, which makes the environment match the heads of that branch in all three repos.
- **Build once.** Packages are stored by **git tree** (`packages/<component>/<tree>/`). A promotion merge
  produces the same tree, so QA, Staging and Prod run the bytes Dev built. Nothing is rebuilt per environment.
- **Gates.** Staging only accepts trees QA has run. Production only accepts what Staging runs (hotfixes excepted).
- **One deploy routine.** `scripts/NtisDeploy.psm1` deploys one tenant as one transaction:
  backup, stop, migrate, publish, config, stamp, start, health check. It restores the backup automatically on failure.
- **Governed PRs.** `pipeline / pr-policy` checks source→target, naming, ticket IDs, release versions and pending
  back-merges. Rulesets require it along with the repo's `build-and-test`.

## Layout

| Path | What |
| --- | --- |
| `.github/workflows/deploy-env.yml` | Orchestrator: resolve → build missing → gate → deploy per tenant → record → finalize |
| `.github/workflows/deploy-tenant.yml` | One tenant, one job, automatic rollback |
| `.github/workflows/build-component.yml` | Build one component at one commit, store by tree (idempotent, immutable) |
| `.github/workflows/app-pipeline.yml` | Reusable workflow the app repos call (`pr-policy`, dispatch on push) |
| `.github/workflows/release-finalize.yml` | Tags `vX.Y.Z`, release manifest, GitHub Release, back-merge PRs |
| `.github/workflows/open-promotion-prs.yml` | Opens `develop→qa`, `qa→staging`, `staging→main` PR sets |
| `.github/workflows/rollback.yml` | Redeploy an earlier release/history entry (approval required) |
| `.github/workflows/backmerge-reminder.yml` | Daily reminder for stale back-merge PRs |
| `.github/workflows/devops-ci.yml` | actionlint + Pester (Windows PowerShell 5.1 and 7) for this repo |
| `.github/actions/package-build` | Build logic for ui / platform / dbmanager (replaces the per-repo copies) |
| `.github/actions/pr-policy` | The PR policy check |
| `scripts/NtisPipeline.psm1` | Env mapping, PR policy, gates, diff, state, GitHub/Blob wrappers |
| `scripts/NtisDeploy.psm1` | IIS/service control, backup/restore, migrate, publish, config, health |
| `config/*.json` | Branch→env map, PR rules, per-component deploy rules |
| `governance/` | Rulesets + `Set-Governance.ps1` (applies repo/branch/environment settings) |
| `scripts/setup/Initialize-EnvBranches.ps1` | Creates/aligns `develop`, `qa`, `staging` in the app repos |
| `templates/app-repo/` | Files to add to each app repo |
| `tests/` | Pester tests |
| `docs/RUNBOOK.md` | How to promote, release, hotfix, roll back, onboard a tenant, and set everything up |

### Interim workflows (retired at cutover, plan 6.4)

| Workflow | Status |
| --- | --- |
| `cd-dynamic-deploy.yml` | Manual deploy of legacy version-numbered packages. Now approval-gated, single job, automatic rollback, runs migrations |
| `ntis-citizen.yml` | Live Citizen site from `feature/rts`. Now approval-gated with backup/rollback. Retires when Citizen becomes a tenant (6.3) |
| `create-package.yml` | Legacy packaging (uses each app repo's own `package-build` action) |
| ~~`cd-orchestrated.yml`~~ | Removed: superseded, and had the `sc` alias and undefined-variable bugs |

## Run the tests

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck
Invoke-Pester ./tests -Output Detailed
```
