<#
.SYNOPSIS
    Opens the promotion PRs for one stage in every component repo that has something to promote
    (playbook sec. 3: develop -> qa, qa -> staging, staging|release/X.Y.Z -> main).
    PRs carry the 'promotion' label so the orchestrator deploys once, after the last one merges.
    Env: GH_TOKEN (app token: pull-requests write on the app repos).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('develop-to-qa', 'qa-to-staging', 'staging-to-main', 'release-to-main')] [string] $Promotion,
    [Parameter(Mandatory)] [string] $Ticket,
    [string] $Version = '',
    [string] $ReleaseBranch = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'NtisPipeline.psm1') -Force -DisableNameChecking
$config = Get-NtisPipelineConfig
$policy = Get-NtisPrPolicy

if ($Ticket -notmatch "^$($policy.ticketPattern)$") { throw "Ticket '$Ticket' does not match $($policy.ticketPattern)." }

switch ($Promotion) {
    'develop-to-qa' { $from = 'develop'; $to = 'qa' }
    'qa-to-staging' { $from = 'qa'; $to = 'staging' }
    'staging-to-main' { $from = 'staging'; $to = 'main' }
    'release-to-main' {
        if ($ReleaseBranch -notmatch '^release/\d+\.\d+\.\d+$') { throw "ReleaseBranch must be release/X.Y.Z (got '$ReleaseBranch')." }
        $from = $ReleaseBranch; $to = 'main'
        if (-not $Version) { $Version = $ReleaseBranch.Substring('release/'.Length) }
    }
}
if ($to -eq 'main' -and -not (ConvertTo-NtisSemVer $Version)) { throw 'Promotions into main need -Version X.Y.Z (playbook sec. 3.3, semver).' }

$title = "${Ticket}: promote $from -> $to"
if ($to -eq 'main') { $title = "${Ticket}: release v$Version ($from -> main)" }

$rows = @("### Promotion $from -> $to", '| Repo | Result |', '| --- | --- |')
foreach ($def in (Get-NtisComponent -Config $config)) {
    $repo = "$($config.owner)/$($def.repo)"
    if (-not (Get-NtisRefHead -Repo $repo -Ref $from)) { $rows += "| $repo | no ``$from`` branch - skipped |"; continue }
    if (-not (Get-NtisRefHead -Repo $repo -Ref $to)) { throw "$repo has no '$to' branch. Run scripts/setup/Initialize-EnvBranches.ps1." }
    if (Test-NtisBranchContains -Repo $repo -Base $to -Head $from) { $rows += "| $repo | nothing to promote |"; continue }

    $existing = @(Get-NtisOpenPulls -Repo $repo -Base $to | Where-Object { $_.head.ref -eq $from })
    if ($existing.Count -gt 0) {
        $rows += "| $repo | already open: #$($existing[0].number) |"
        continue
    }
    Initialize-NtisLabel -Repo $repo -Name 'promotion' -Color '0e8a16' -Description 'Environment promotion (deploys when the whole set is merged)'
    $body = @"
Promotion **$from -> $to** opened by the release pipeline.

- Merge with **Create a merge commit** (never squash a promotion - it breaks build-once promotion).
- The deploy to **$to** starts when the last open ``promotion`` PR into ``$to`` across ntis-ui / ntis-platform / ntis-database-manager is merged.
- Merge all of the set, or close all of it.
"@
    $pr = Invoke-NtisGhWrite -Method POST -Path "repos/$repo/pulls" -Body @{ title = $title; head = $from; base = $to; body = $body }
    Invoke-NtisGhWrite -Method POST -Path "repos/$repo/issues/$($pr.number)/labels" -Body @{ labels = @('promotion') } | Out-Null
    $rows += "| $repo | opened [#$($pr.number)]($($pr.html_url)) |"
}
Write-NtisSummary -Markdown ($rows -join "`n")
exit 0
