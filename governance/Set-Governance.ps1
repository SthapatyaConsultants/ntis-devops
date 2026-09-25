<#
.SYNOPSIS
    Applies the GitHub settings the branching playbook depends on (plan tasks 1.5, 1.6, 1.10).
.DESCRIPTION
    Run by an org admin from a workstation with `gh auth login` done. Dry-run by default; add -Apply to change anything.

    App repos (ntis-ui, ntis-platform, ntis-database-manager):
      * merge settings: squash + merge commit on, rebase off, auto-delete head branches on
      * labels: promotion, back-merge
      * rulesets from governance/rulesets/*.json (PR required, approvals, code owners, required checks,
        merge methods per branch, no force-push, no deletion of env branches)
      * push restrictions (who may merge) on qa, staging, main
    ntis-devops:
      * Actions access: reusable workflows/actions usable by the org's repos
      * Environments dev / qa / staging / production (+ *-manual with required reviewers)

.EXAMPLE
    ./governance/Set-Governance.ps1                 # show what would change
    ./governance/Set-Governance.ps1 -Apply          # apply
#>
[CmdletBinding()]
param(
    [string] $Owner = 'SthapatyaConsultants',
    [string[]] $AppRepos = @('ntis-ui', 'ntis-platform', 'ntis-database-manager'),
    [string] $DevopsRepo = 'ntis-devops',
    [string] $CiCheck = 'build-and-test',
    [string] $ReleaseManagersTeam = 'ntis-release-managers',
    [string] $TechLeadsTeam = 'ntis-tech-leads',
    [string] $QaLeadsTeam = 'ntis-qa-leads',
    [switch] $Apply
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\scripts\NtisPipeline.psm1') -Force -DisableNameChecking

function Invoke-Change([string] $What, [scriptblock] $Action) {
    if ($Apply) { Write-Host "APPLY  $What"; & $Action } else { Write-Host "WOULD  $What" }
}

# ---- teams -------------------------------------------------------------
$teamIds = @{}
foreach ($slug in @($ReleaseManagersTeam, $TechLeadsTeam, $QaLeadsTeam)) {
    $t = Invoke-NtisGhJson -Path "orgs/$Owner/teams/$slug" -AllowNotFound
    if (-not $t) { Write-Warning "Team @$Owner/$slug does not exist - create it and add members first (plan 1.4)."; continue }
    $teamIds[$slug] = $t.id
}

$pushers = @{
    qa      = @($QaLeadsTeam, $TechLeadsTeam)
    staging = @($ReleaseManagersTeam, $TechLeadsTeam)
    main    = @($ReleaseManagersTeam)
}

# ---- app repos -----------------------------------------------------------
foreach ($name in $AppRepos) {
    $repo = "$Owner/$name"
    Write-Host "`n=== $repo"

    Invoke-Change "merge settings on $repo" {
        Invoke-NtisGhWrite -Method PATCH -Path "repos/$repo" -Body @{
            allow_squash_merge = $true; allow_merge_commit = $true; allow_rebase_merge = $false
            delete_branch_on_merge = $true; squash_merge_commit_title = 'PR_TITLE'; squash_merge_commit_message = 'PR_BODY'
        } | Out-Null
    }
    Invoke-Change "labels promotion/back-merge on $repo" {
        Initialize-NtisLabel -Repo $repo -Name 'promotion' -Color '0e8a16' -Description 'Environment promotion (deploys when the whole set is merged)'
        Initialize-NtisLabel -Repo $repo -Name 'back-merge' -Color 'd93f0b' -Description 'Automatic main -> env-branch sync after a release'
    }

    $existing = @(Invoke-NtisGhList -Path "repos/$repo/rulesets?per_page=100")
    foreach ($file in (Get-ChildItem (Join-Path $PSScriptRoot 'rulesets') -Filter *.json)) {
        $body = Get-Content $file.FullName -Raw | ConvertFrom-Json
        foreach ($rule in $body.rules) {
            if ($rule.type -eq 'required_status_checks') {
                foreach ($chk in $rule.parameters.required_status_checks) { if ($chk.context -eq 'build-and-test') { $chk.context = $CiCheck } }
            }
        }
        $match = @($existing | Where-Object { $_.name -eq $body.name }) | Select-Object -First 1
        if ($match) {
            Invoke-Change "update ruleset '$($body.name)' on $repo" { Invoke-NtisGhWrite -Method PUT -Path "repos/$repo/rulesets/$($match.id)" -Body $body | Out-Null }
        } else {
            Invoke-Change "create ruleset '$($body.name)' on $repo" { Invoke-NtisGhWrite -Method POST -Path "repos/$repo/rulesets" -Body $body | Out-Null }
        }
    }

    foreach ($branch in $pushers.Keys) {
        if (-not (Get-NtisRefHead -Repo $repo -Ref $branch)) { Write-Warning "$repo has no '$branch' branch yet - run scripts/setup/Initialize-EnvBranches.ps1, then re-run this."; continue }
        $teams = @($pushers[$branch] | Where-Object { $teamIds.ContainsKey($_) })
        Invoke-Change "restrict merges into $repo/$branch to teams: $($teams -join ', ')" {
            Invoke-NtisGhWrite -Method PUT -Path "repos/$repo/branches/$branch/protection" -Body @{
                required_status_checks = $null; enforce_admins = $true; required_pull_request_reviews = $null
                restrictions = @{ users = @(); teams = $teams; apps = @() }
                allow_force_pushes = $false; allow_deletions = $false
            } | Out-Null
        }
    }
}

# ---- ntis-devops ---------------------------------------------------------
$devops = "$Owner/$DevopsRepo"
Write-Host "`n=== $devops"
Invoke-Change "Actions access level 'organization' on $devops" {
    Invoke-NtisGhWrite -Method PUT -Path "repos/$devops/actions/permissions/access" -Body @{ access_level = 'organization' } | Out-Null
}

$environments = [ordered]@{
    'dev'               = @()
    'qa'                = @()
    'staging'           = @()
    'production'        = @()
    'dev-manual'        = @($TechLeadsTeam, $ReleaseManagersTeam)
    'qa-manual'         = @($QaLeadsTeam, $TechLeadsTeam, $ReleaseManagersTeam)
    'staging-manual'    = @($ReleaseManagersTeam, $TechLeadsTeam)
    'production-manual' = @($ReleaseManagersTeam)
}
foreach ($envName in $environments.Keys) {
    $reviewers = @($environments[$envName] | Where-Object { $teamIds.ContainsKey($_) } | ForEach-Object { @{ type = 'Team'; id = $teamIds[$_] } })
    $body = @{ deployment_branch_policy = @{ protected_branches = $false; custom_branch_policies = $true } }
    if ($reviewers.Count -gt 0) { $body.reviewers = $reviewers; $body.prevent_self_review = $false }
    Invoke-Change "environment '$envName' on $devops (runs from main only; reviewers: $(@($environments[$envName]) -join ', '))" {
        Invoke-NtisGhWrite -Method PUT -Path "repos/$devops/environments/$envName" -Body $body | Out-Null
        $policies = Invoke-NtisGhJson -Path "repos/$devops/environments/$envName/deployment-branch-policies"
        if (-not (@($policies.branch_policies) | Where-Object { $_.name -eq 'main' })) {
            Invoke-NtisGhWrite -Method POST -Path "repos/$devops/environments/$envName/deployment-branch-policies" -Body @{ name = 'main'; type = 'branch' } | Out-Null
        }
    }
}

Write-Host @"

Still manual (see docs/RUNBOOK.md - 'One-time setup'):
  * GitHub App ntis-cicd-bot (Contents RW, Pull requests RW, Issues RW, Actions R, Metadata R) installed on
    ntis-ui, ntis-platform, ntis-database-manager, ntis-devops, ntis-configs; org variable CICD_APP_ID and
    org secret CICD_APP_KEY (visible to those repos).
  * Storage: containers ntis-packages (version-level immutability) and ntis-state; secret NTIS_STORAGE_CONNECTION_STRING.
  * Runner labels ntis-build, ntis-deploy-nonprod, ntis-deploy-prod (or repo variables NTIS_RUNNER_*).
  * Environment secrets for #{TOKEN}# config values in dev / qa / staging / production.
"@
if (-not $Apply) { Write-Host "`nDry run only. Re-run with -Apply to make these changes." }
exit 0
