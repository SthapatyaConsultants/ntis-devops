<#
.SYNOPSIS
    Finds back-merge PRs open longer than -WorkingDays and keeps one tracking issue in ntis-devops up to date
    (playbook sec. 5: "Never let a hotfix exist only on main").
    Env: GH_TOKEN (app token: read app repos, issues write on ntis-devops), GITHUB_REPOSITORY.
#>
[CmdletBinding()]
param([int] $WorkingDays = 2, [string] $Mention = '@SthapatyaConsultants/ntis-release-managers')

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'NtisPipeline.psm1') -Force -DisableNameChecking
$config = Get-NtisPipelineConfig

function Get-WorkingDaysSince([datetime] $since) {
    $days = 0; $d = $since.Date
    while ($d -lt (Get-Date).Date) {
        $d = $d.AddDays(1)
        if ($d.DayOfWeek -ne 'Saturday' -and $d.DayOfWeek -ne 'Sunday') { $days++ }
    }
    return $days
}

$stale = @()
foreach ($def in (Get-NtisComponent -Config $config)) {
    $repo = "$($config.owner)/$($def.repo)"
    foreach ($pr in (Get-NtisOpenPulls -Repo $repo -Label 'back-merge')) {
        $age = Get-WorkingDaysSince ([datetime]$pr.created_at)
        if ($age -ge $WorkingDays) { $stale += "- [ ] $repo#$($pr.number) ``$($pr.head.ref)`` -> ``$($pr.base.ref)`` - open $age working days" }
    }
}

$title = 'Stale back-merge PRs'
$issues = Invoke-NtisGhList -Path "repos/$env:GITHUB_REPOSITORY/issues?state=open&labels=back-merge&per_page=100"
$issue = @($issues | Where-Object { $_.title -eq $title }) | Select-Object -First 1

if ($stale.Count -eq 0) {
    if ($issue) {
        Invoke-NtisGhWrite -Method PATCH -Path "repos/$env:GITHUB_REPOSITORY/issues/$($issue.number)" -Body @{ state = 'closed'; state_reason = 'completed' } | Out-Null
        Write-Host "No stale back-merges; closed #$($issue.number)."
    } else { Write-Host 'No stale back-merges.' }
    exit 0
}

Initialize-NtisLabel -Repo $env:GITHUB_REPOSITORY -Name 'back-merge' -Color 'd93f0b'
$body = "$Mention these back-merge PRs have been open for $WorkingDays+ working days. Until they merge, the next release can re-introduce the bug they fix (playbook sec. 5).`n`n" + ($stale -join "`n")
if ($issue) {
    Invoke-NtisGhWrite -Method PATCH -Path "repos/$env:GITHUB_REPOSITORY/issues/$($issue.number)" -Body @{ body = $body } | Out-Null
} else {
    Invoke-NtisGhWrite -Method POST -Path "repos/$env:GITHUB_REPOSITORY/issues" -Body @{ title = $title; body = $body; labels = @('back-merge') } | Out-Null
}
Write-NtisSummary -Markdown ("### Stale back-merges`n" + ($stale -join "`n"))
exit 0
