<#
.SYNOPSIS
    After a successful production deploy (design sec. 2.10, sec. 2.11):
      1. annotated tag vX.Y.Z on the deployed commit of every component repo (+ ntis-devops)
      2. releases/vX.Y.Z.json manifest (used by rollback)
      3. GitHub Release in ntis-devops
      4. back-merge PRs main -> staging, qa, develop wherever main has changes the branch lacks (sec. 5, sec. 7)
    Env: GH_TOKEN (app token: contents + pull-requests write on all repos), AZURE_STORAGE_CONNECTION_STRING,
         GITHUB_REPOSITORY (ntis-devops), GITHUB_SHA.
#>
[CmdletBinding()]
param(
    [string] $Version = '',
    [string] $RunUrl = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'NtisPipeline.psm1') -Force -DisableNameChecking
$config = Get-NtisPipelineConfig
$containers = Get-NtisContainerNames
$owner = $config.owner

$state = Get-NtisBlobJson -Container $containers.State -Name 'state/production/current.json'
if (-not $state) { throw 'state/production/current.json not found; nothing to finalize.' }

$summary = @('### Release finalize')

if (-not $Version) {
    Write-Warning 'No release version (the merged PR title had no vX.Y.Z). Skipping tags and GitHub Release; back-merges still run.'
    $summary += '- No version: tags and GitHub Release skipped.'
} elseif (-not (ConvertTo-NtisSemVer $Version)) {
    throw "Version '$Version' is not X.Y.Z."
} else {
    $tag = "v$Version"
    # 1. tags on the deployed commits
    foreach ($p in $state.components.PSObject.Properties) {
        $c = $p.Value
        $repo = $c.repo
        $exists = Invoke-NtisGhJson -Path "repos/$repo/git/ref/tags/$tag" -AllowNotFound
        if ($exists) {
            if ($exists.object.type -eq 'tag') {
                $tagObj = Invoke-NtisGhJson -Path "repos/$repo/git/tags/$($exists.object.sha)"
                $target = $tagObj.object.sha
            } else { $target = $exists.object.sha }
            if ($target -ne $c.commitSha) { Write-Warning "$repo already has $tag on $target (deployed $($c.commitSha)); left unchanged." }
            else { Write-Host "$repo $tag already exists." }
            continue
        }
        $obj = Invoke-NtisGhWrite -Method POST -Path "repos/$repo/git/tags" -Body @{
            tag = $tag; object = $c.commitSha; type = 'commit'
            message = "NTIS release $tag`n`nDeployed to production by $RunUrl"
        }
        Invoke-NtisGhWrite -Method POST -Path "repos/$repo/git/refs" -Body @{ ref = "refs/tags/$tag"; sha = $obj.sha } | Out-Null
        Write-Host "Tagged $repo@$($c.commitSha.Substring(0,10)) as $tag"
        $summary += "- Tagged ``$repo`` ``$($c.commitSha.Substring(0,10))`` as **$tag**"
    }

    # 2. manifest
    $manifest = [ordered]@{ version = $Version; releasedAt = (Get-Date).ToUniversalTime().ToString('o'); runUrl = $RunUrl; components = $state.components }
    if (-not (Test-NtisBlob -Container $containers.State -Name "releases/$tag.json")) {
        Set-NtisBlobJson -Container $containers.State -Name "releases/$tag.json" -Value $manifest
    }

    # 3. GitHub Release in ntis-devops
    $devops = $env:GITHUB_REPOSITORY
    $rel = Invoke-NtisGhJson -Path "repos/$devops/releases/tags/$tag" -AllowNotFound
    if (-not $rel) {
        $rows = @('| Component | Repo | Commit | Tree |', '| --- | --- | --- | --- |')
        foreach ($p in $state.components.PSObject.Properties) {
            $rows += "| $($p.Name) | $($p.Value.repo) | ``$($p.Value.commitSha.Substring(0,10))`` | ``$($p.Value.tree.Substring(0,10))`` |"
        }
        $body = "NTIS $tag deployed to production.`n`n" + ($rows -join "`n") + "`n`nDeploy run: $RunUrl"
        Invoke-NtisGhWrite -Method POST -Path "repos/$devops/releases" -Body @{
            tag_name = $tag; target_commitish = $env:GITHUB_SHA; name = "NTIS $tag"; body = $body; make_latest = 'true'
        } | Out-Null
        $summary += "- GitHub Release **$tag** created in ``$devops``"
    }
}

# 4. back-merges (every release; design G2)
$label = 'back-merge'
$suffix = 'release'
if ($Version) { $suffix = "v$Version" } else { $suffix = 'release-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmm') }
foreach ($def in (Get-NtisComponent -Config $config)) {
    $repo = "$owner/$($def.repo)"
    $main = Get-NtisRefHead -Repo $repo -Ref 'main'
    Initialize-NtisLabel -Repo $repo -Name $label -Color 'd93f0b' -Description 'Automatic main -> env-branch sync after a release'
    foreach ($target in @('staging', 'qa', 'develop')) {
        if (-not (Get-NtisRefHead -Repo $repo -Ref $target)) { Write-Warning "$repo has no '$target' branch."; continue }
        if (Test-NtisBranchContains -Repo $repo -Base $target -Head 'main') { continue }

        $branch = "backmerge/$suffix-$target"
        if (-not (Get-NtisRefHead -Repo $repo -Ref $branch)) {
            Invoke-NtisGhWrite -Method POST -Path "repos/$repo/git/refs" -Body @{ ref = "refs/heads/$branch"; sha = $main.Sha } | Out-Null
        }
        $open = @(Get-NtisOpenPulls -Repo $repo -Base $target | Where-Object { $_.head.ref -eq $branch })
        if ($open.Count -gt 0) { continue }
        $pr = Invoke-NtisGhWrite -Method POST -Path "repos/$repo/pulls" -Body @{
            title = "Back-merge $suffix into $target"
            head  = $branch
            base  = $target
            body  = "Automatic back-merge after the production release ($RunUrl).`n`nPlaybook sec. 5/sec. 7: fixes on ``main`` must reach ``staging``, ``qa`` and ``develop``. Use **Create a merge commit**. If there are conflicts, resolve them on ``$branch`` - never on ``main``."
        }
        Invoke-NtisGhWrite -Method POST -Path "repos/$repo/issues/$($pr.number)/labels" -Body @{ labels = @($label) } | Out-Null
        Write-Host "Opened $repo#$($pr.number) $branch -> $target"
        $summary += "- Back-merge PR ``$repo#$($pr.number)`` into ``$target``"
    }
}

Write-NtisSummary -Markdown ($summary -join "`n")
exit 0
