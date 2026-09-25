# NTIS CI/CD runbook

## One-time setup

1. **Confirm the GitHub plan** supports rulesets, branch push restrictions and environment protection on
   private repos (design OD-1).
2. **Create teams**: `ntis-release-managers`, `ntis-tech-leads`, `ntis-qa-leads`, `ntis-developers`. Add members.
3. **GitHub App `ntis-cicd-bot`**: permissions Contents RW, Pull requests RW, Issues RW, Actions R, Metadata R.
   Install on `ntis-ui`, `ntis-platform`, `ntis-database-manager`, `ntis-devops`, `ntis-configs`.
   Org variable `CICD_APP_ID`, org secret `CICD_APP_KEY` (visible to those five repos).
4. **Azure Blob**: containers `ntis-packages` (versioning + version-level immutability) and `ntis-state`
   (versioning). Secret `NTIS_STORAGE_CONNECTION_STRING` (or reuse `PACKAGE_CONNECTION_STRING`) on `ntis-devops`.
5. **Runners**: labels `ntis-build`, `ntis-deploy-nonprod`, `ntis-deploy-prod` (separate Windows service
   accounts; the prod account alone has IIS/NTFS rights on prod paths). `ntis-build` needs `gh`, `az`, Node,
   .NET SDK, PowerShell 7.
6. **Branches**: `./scripts/setup/Initialize-EnvBranches.ps1 -Apply` in `ntis-devops`, then merge the alignment
   PRs it opens (main→staging, staging→qa, qa→develop, in that order) and re-run until it reports everything aligned.
7. **Governance**: `./governance/Set-Governance.ps1 -Apply` in `ntis-devops` (rulesets, merge settings, push
   restrictions, GitHub Environments `dev`/`qa`/`staging`/`production` + `*-manual`).
8. **App repos**: apply `templates/app-repo/` (see its README) - caller workflow, CODEOWNERS, PR template,
   and point each repo's own CI job at the env branches, keeping the job id `build-and-test`.
9. **Environment secrets**: for each of `dev`/`qa`/`staging`/`production`, add the `#{TOKEN}#` secrets your
   `ntis-configs` files reference (e.g. `DB_PASSWORD`). Required reviewers on `production` stay empty (playbook
   §3.3: merging to `main` deploys immediately); reviewers go on `production-manual` instead.
10. **Staging tenants**: pick 1-2 representative tenants (design OD-6), stand up IIS sites/services, add them
    to `ntis-configs/tenants.json` with `"environment": "staging"`.

## Everyday flow

### Ship a feature
```
git checkout develop && git pull
git checkout -b feature/PROJ-214-login-otp
# commit, push, open a PR into develop (ticket ID in the title)
# 1 review + build-and-test + pr-policy green -> Squash and merge
```

### Promote Dev → QA / QA → Staging
```
gh workflow run open-promotion-prs.yml -f promotion=develop-to-qa -f ticket=REL-12
```
Merge the opened PR(s) in all three repos with **Create a merge commit**. The deploy to QA starts once the
last one merges (`deploy-env.yml` waits for every open `promotion` PR into the target branch to close).
Same command with `promotion=qa-to-staging` for the next stage.

### Release Staging → Production
```
gh workflow run open-promotion-prs.yml -f promotion=staging-to-main -f ticket=REL-12 -f version=2.5.0
```
Two release-manager approvals, merge commit. On merge: production deploy, then automatically -
tag `v2.5.0` in all three repos, a GitHub Release, and back-merge PRs into `staging`/`qa`/`develop`.
**Merge those back-merge PRs** (merge commit) - `qa-to-staging` is blocked while one into `qa` is open.

### Release branch (bigger release, scope freeze)
```
git checkout develop && git pull && git checkout -b release/2.5.0 && git push -u origin release/2.5.0
# only bugfix/* PRs land on release/2.5.0 (squash)
```
`release/2.5.0` deploys to Staging automatically (it is picked over the `staging` branch while it exists -
only one `release/*` branch may be open at a time). When approved:
```
gh workflow run open-promotion-prs.yml -f promotion=release-to-main -f ticket=REL-13 -f release_branch=release/2.5.0
```
Same tag/back-merge automation follows. Delete `release/2.5.0` after the back-merges land.

### Hotfix
```
git checkout main && git pull && git checkout -b hotfix/PROJ-301-payment-crash
# fix + test, PR into main titled "PROJ-301: fix v2.4.1" (PATCH bump), 2 approvals, merge commit
```
Deploys to production immediately, tags `v2.4.1`, opens back-merge PRs into staging/qa/develop - merge all
three before the next regular promotion.

### Roll back
```
gh workflow run rollback.yml -f environment=production -f target=previous -f reason="v2.5.0 API 500s"
# or: -f target=v2.4.0   (a tagged release)  /  -f tenant=<url>  (one tenant only)
```
Requires `production-manual` approval. Code only - database migrations are not reversed; check the release's
manifest (`releases/vX.Y.Z.json`) before rolling back past a migration.

### Onboard a tenant
Add an entry to `ntis-configs/tenants.json` (`environment`, `tenant`, `apiSite`, `apiPath`, `uiPath`,
`uiService`, optionally `workerPath`/`workerService`, `apiHealthUrl`, `migrateDatabase`, `applyConfig`), add
its config files under `ntis-configs/tenants/<tenant>/<env>/`, and create the IIS site/pool/service. The next
deploy to that environment picks it up.

### A deploy failed
The job restores the pre-deploy backup and restarts services automatically - check the run's summary for
"rolled back". If services are still down, backups are at `C:\Backup\<tenant>\<env>\<timestamp>` on the host;
`Restore-NtisTenant` in `scripts/NtisDeploy.psm1` can be run by hand if needed. Migrations are never
auto-reverted - fix forward or restore the database from its own backup (design OD-5).

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| `pr-policy` fails with "may not merge into" | Wrong target branch, or branch name doesn't match `feature\|bugfix\|hotfix/<TICKET>-<slug>` / `release/X.Y.Z` |
| Promotion gate fails "tree ... was never deployed to QA" | Someone merged straight into `staging`, or squashed a promotion (changes the tree) - promote through `qa` first |
| `deploy-env` stays "waiting" | Another `promotion`-labelled PR into that branch is still open in one of the three repos |
| `Resolve-Rollback` throws "package ... no longer exists" | The package aged out of Blob before the rollback ran; use an earlier target or rebuild from the tag |
