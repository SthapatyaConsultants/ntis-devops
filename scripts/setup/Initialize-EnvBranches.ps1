<#
.SYNOPSIS
    Creates the playbook's long-lived branches in each app repo and checks they nest correctly (plan task 1.3).
.DESCRIPTION
    For each app repo:
      1. renames 'dev' to 'develop' (GitHub retargets open PRs; old URLs redirect)
      2. creates 'staging' from 'main' if missing ('qa' from 'develop' if missing)
      3. checks main <= staging <= qa <= develop. Wherever a branch has changes its successor lacks, it
         opens an alignment PR from backmerge/align-<from>-to-<to> (a copy of <from>) - merge those with a
         merge commit, then re-run until everything is aligned.
    Dry-run by default; -Apply makes changes. Requires admin on the repos (branch rename).
#>
[CmdletBinding()]
param(
    [string] $Owner = 'SthapatyaConsultants',
    [string[]] $AppRepos = @('ntis-ui', 'ntis-platform', 'ntis-database-manager'),
    [switch] $Apply
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\NtisPipeline.psm1') -Force -DisableNameChecking

function Invoke-Change([string] $What, [scriptblock] $Action) {
    if ($Apply) { Write-Host "APPLY  $What"; & $Action } else { Write-Host "WOULD  $What" }
}

$aligned = $true
foreach ($name in $AppRepos) {
    $repo = "$Owner/$name"
    Write-Host "`n=== $repo"

    $dev = Get-NtisRefHead -Repo $repo -Ref 'dev'
    $develop = Get-NtisRefHead -Repo $repo -Ref 'develop'
    if ($dev -and -not $develop) {
        Invoke-Change "rename $repo 'dev' -> 'develop'" { Invoke-NtisGhWrite -Method POST -Path "repos/$repo/branches/dev/rename" -Body @{ new_name = 'develop' } | Out-Null }
    } elseif ($dev -and $develop) {
        Write-Warning "$repo has both 'dev' and 'develop'. Merge dev into develop by PR, then delete dev."
    } elseif (-not $develop) {
        throw "$repo has neither 'dev' nor 'develop'."
    }

    $main = Get-NtisRefHead -Repo $repo -Ref 'main'
    if (-not (Get-NtisRefHead -Repo $repo -Ref 'staging')) {
        Invoke-Change "create $repo 'staging' from main ($($main.Sha.Substring(0,10)))" {
            Invoke-NtisGhWrite -Method POST -Path "repos/$repo/git/refs" -Body @{ ref = 'refs/heads/staging'; sha = $main.Sha } | Out-Null
        }
    }
    if (-not (Get-NtisRefHead -Repo $repo -Ref 'qa')) {
        $src = Get-NtisRefHead -Repo $repo -Ref 'develop'; if (-not $src) { $src = $dev }
        Invoke-Change "create $repo 'qa' from develop" {
            Invoke-NtisGhWrite -Method POST -Path "repos/$repo/git/refs" -Body @{ ref = 'refs/heads/qa'; sha = $src.Sha } | Out-Null
        }
    }
    if (-not $Apply) { $developName = if ($develop) { 'develop' } else { 'dev' } } else { $developName = 'develop' }

    foreach ($pair in @(@('main', 'staging'), @('staging', 'qa'), @('qa', $developName))) {
        $from = $pair[0]; $to = $pair[1]
        if (-not (Get-NtisRefHead -Repo $repo -Ref $from) -or -not (Get-NtisRefHead -Repo $repo -Ref $to)) {
            Write-Host "  (skip $from -> ${to}: branch will exist after -Apply)"; continue
        }
        if (Test-NtisBranchContains -Repo $repo -Base $to -Head $from) { Write-Host "  ok: $to contains $from"; continue }
        $aligned = $false
        $branch = "backmerge/align-$from-to-$to"
        $open = @(Get-NtisOpenPulls -Repo $repo -Base $to | Where-Object { $_.head.ref -eq $branch })
        if ($open.Count -gt 0) { Write-Host "  pending: $repo#$($open[0].number) aligns $from into $to"; continue }
        Invoke-Change "open alignment PR $from -> $to in $repo" {
            $head = Get-NtisRefHead -Repo $repo -Ref $from
            if (-not (Get-NtisRefHead -Repo $repo -Ref $branch)) {
                Invoke-NtisGhWrite -Method POST -Path "repos/$repo/git/refs" -Body @{ ref = "refs/heads/$branch"; sha = $head.Sha } | Out-Null
            }
            $pr = Invoke-NtisGhWrite -Method POST -Path "repos/$repo/pulls" -Body @{
                title = "Align $from into $to (branching strategy setup)"; head = $branch; base = $to
                body  = "One-time alignment so that main <= staging <= qa <= develop (build-once promotion relies on it). Use **Create a merge commit**."
            }
            Write-Host "  opened $repo#$($pr.number)"
        }
    }
}

if ($aligned) { Write-Host "`nAll repos nest correctly: main <= staging <= qa <= develop." }
else { Write-Host "`nMerge the alignment PRs (in order main->staging, staging->qa, qa->develop) and re-run until aligned." }
if (-not $Apply) { Write-Host 'Dry run only. Re-run with -Apply to make these changes.' }
exit 0
