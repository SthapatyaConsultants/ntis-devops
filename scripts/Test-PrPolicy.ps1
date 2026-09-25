<#
.SYNOPSIS
    Required PR check "pr-policy" for the NTIS app repos (design sec. 2.5).
.DESCRIPTION
    Reads the pull_request event, gathers repo facts (latest release tag, release branches, open back-merges)
    and evaluates config/pr-policy.json. Writes a job summary, keeps one sticky PR comment up to date,
    and exits 1 when the policy fails.
    Env: GITHUB_EVENT_PATH, GITHUB_REPOSITORY, GH_TOKEN (pull-requests: write on the app repo).
#>
[CmdletBinding()]
param([string] $EventPath = $env:GITHUB_EVENT_PATH, [string] $Repository = $env:GITHUB_REPOSITORY, [switch] $NoComment)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'NtisPipeline.psm1') -Force -DisableNameChecking

$evt = Get-Content $EventPath -Raw | ConvertFrom-Json
if (-not $evt.PSObject.Properties['pull_request']) { Write-Host 'Not a pull_request event; nothing to check.'; exit 0 }
$pr = $evt.pull_request
$base = [string]$pr.base.ref
$head = [string]$pr.head.ref
$title = [string]$pr.title
$policy = Get-NtisPrPolicy

# Facts are only fetched when a rule needs them (keeps the check fast for feature PRs).
$facts = @{}
if ($base -eq 'main') {
    $facts['LatestVersion'] = Get-NtisLatestSemVer -Tags (Get-NtisTagNames -Repo $Repository)
}
if ($base -like 'release/*') {
    $facts['ReleaseBranches'] = Get-NtisBranchNames -Repo $Repository -Prefix 'release/'
}
if ($base -eq 'staging') {
    $open = @(Get-NtisOpenPulls -Repo $Repository -Base 'qa' | Where-Object { $_.head.ref -like 'backmerge/*' })
    $facts['OpenBackmerges'] = @{ qa = $open.Count }
}

$result = Test-NtisPrPolicy -Base $base -Head $head -Title $title -Policy $policy -Facts $facts

$marker = '<!-- ntis-pr-policy -->'
$lines = @($marker)
if (-not $result.Governed) {
    $lines += "**PR policy:** ``$base`` is not a protected branch - no rules apply."
} elseif ($result.Passed) {
    $lines += "**PR policy passed** for ``$head`` -> ``$base``."
} else {
    $lines += "**PR policy failed** for ``$head`` -> ``$base``:"
    $lines += ''
    foreach ($e in $result.Errors) { $lines += "- $e" }
}
if ($result.Notes.Count -gt 0) { $lines += ''; foreach ($n in $result.Notes) { $lines += "> $n" } }
$lines += ''
$lines += '_Rules: Git Branching & Merging Strategy (ntis-devops/config/pr-policy.json)._'
$body = $lines -join "`n"
Write-NtisSummary -Markdown $body

if (-not $NoComment -and $result.Governed) {
    try {
        $comments = Invoke-NtisGhList -Path "repos/$Repository/issues/$($pr.number)/comments?per_page=100"
        $existing = @($comments | Where-Object { $_.body -and $_.body.StartsWith($marker) }) | Select-Object -First 1
        $tmp = [System.IO.Path]::GetTempFileName()
        (@{ body = $body } | ConvertTo-Json) | Set-Content -Path $tmp -Encoding UTF8
        if ($existing) {
            Invoke-NtisGh -Arguments @('api', '-X', 'PATCH', "repos/$Repository/issues/comments/$($existing.id)", '--input', $tmp) | Out-Null
        } elseif (-not $result.Passed) {
            Invoke-NtisGh -Arguments @('api', '-X', 'POST', "repos/$Repository/issues/$($pr.number)/comments", '--input', $tmp) | Out-Null
        }
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Warning "Could not update the PR comment: $($_.Exception.Message)"
    }
}

if (-not $result.Passed) {
    foreach ($e in $result.Errors) { Write-Host "::error title=PR policy::$e" }
    exit 1
}
Write-Host 'PR policy passed.'
exit 0
