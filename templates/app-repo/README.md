# App repo changes (ntis-ui, ntis-platform, ntis-database-manager)

Apply these in each app repo through a normal PR, after `scripts/setup/Initialize-EnvBranches.ps1` has
created `develop` / `qa` / `staging` (plan tasks 1.3, 2.3).

## 1. Add the caller workflow, CODEOWNERS and PR template

Copy from this folder:

| File | Purpose |
| --- | --- |
| `.github/workflows/pipeline.yml` | Required check `pipeline / pr-policy`; notifies `ntis-devops` when `develop`/`qa`/`staging`/`main`/`release/*` moves |
| `.github/CODEOWNERS` | Reviewer groups (same file on every branch) |
| `.github/pull_request_template.md` | Title and merge-method reminders |

## 2. Make the existing CI the required build check

The rulesets require a check named **`build-and-test`** (the job name the three repos already use).
It must run on every PR into a protected branch; today the triggers differ per repo:

| Repo | Workflow | Today | Change `on:` to |
| --- | --- | --- | --- |
| ntis-ui | `build-and-test.yml` | PR + push to `main`, `dev`, `qa` | see below |
| ntis-platform | `ci.yml` | PR to `main*`, `dev*`, `feature*` | see below |
| ntis-database-manager | `ci.yml` | PR to `main*` | see below |

```yaml
on:
  pull_request:
    branches: [develop, qa, staging, main, 'release/**']
  workflow_dispatch:
```

Keep the job id `build-and-test`. If you rename it, pass `-CiCheck <name>` to `governance/Set-Governance.ps1`.
Note: `ntis-ui` also runs its CI on `push`; that can stay, but it is no longer needed - deploys are driven by `pipeline.yml`.

## 3. After cutover (plan 6.4)

Delete `.github/workflows/package-build.yml` and `.github/actions/package-build/` - packaging now lives in
`ntis-devops/.github/actions/package-build` and is keyed by git tree, not by a typed version.

## Notes per repo

- **ntis-ui**: the committed `.env` is bundled into the build but never deployed over a server's `.env`
  (it is a preserved file). Server values come from the server or from `ntis-configs` (`applyConfig`).
- **ntis-platform**: the Worker is now packaged (`worker/`) and deployed when a tenant defines
  `workerPath` / `workerService` in `tenants.json`.
- **ntis-database-manager**: deploys run `DatabaseManager.exe U` non-interactively; keep exit codes meaningful.
