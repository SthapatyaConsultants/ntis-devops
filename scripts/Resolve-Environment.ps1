<#
.SYNOPSIS
    First job of deploy-env.yml: works out what an environment should run (design sec. 2.7).
.DESCRIPTION
    Outputs (GITHUB_OUTPUT):
      skip               true when the ref does not deploy
      environment        dev | qa | staging | production
      github_environment GitHub Environment holding the stage's secrets
      tenant_environment value of 'environment' in tenants.json
      runner             deploy runner label
      waiting            true while promotion PRs into the same branch are still open
      components         JSON [{Name,Repo,SourceRef,Sha,Tree,PrHead,PrTitle}] for all components
      missing            JSON [{repo,sha,tree,component}] packages that must be built first
      changed            JSON [{Name,Repo,SourceRef,Sha,Tree}] components to deploy, in order
      tenants            JSON ["url", ...]
      version            release version (production only, from the merged PR title)
    Env: GH_TOKEN (app token with read on the app repos), AZURE_STORAGE_CONNECTION_STRING,
         NTIS_RUNNER_NONPROD / NTIS_RUNNER_PROD (optional overrides).
#>
[CmdletBinding()]
param(
    [string] $Ref,
    [string] $EnvironmentKey,
    [string] $TriggerRepo,
    [string] $TriggerSha,
    [Parameter(Mandatory)] [string] $ConfigRoot,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'NtisPipeline.psm1') -Force -DisableNameChecking

$config = Get-NtisPipelineConfig
$owner = $config.owner
$containers = Get-NtisContainerNames

if (-not $EnvironmentKey) {
    if (-not $Ref) { throw 'Either -Ref or -EnvironmentKey is required.' }
    $EnvironmentKey = Resolve-NtisEnvironmentKey -Ref $Ref -Config $config
}
if (-not $EnvironmentKey) {
    Write-Host "Ref '$Ref' does not map to an environment; nothing to deploy."
    Write-NtisOutput skip 'true'
    exit 0
}
$envDef = Get-NtisEnvironment -Key $EnvironmentKey -Config $config
Write-NtisOutput skip 'false'
Write-NtisOutput environment $EnvironmentKey
Write-NtisOutput github_environment $envDef.githubEnvironment
Write-NtisOutput tenant_environment $envDef.tenantEnvironment

$runner = 'ntis-deploy-nonprod'
if ($envDef.runnerClass -eq 'prod') { $runner = 'ntis-deploy-prod'; if ($env:NTIS_RUNNER_PROD) { $runner = $env:NTIS_RUNNER_PROD } }
elseif ($env:NTIS_RUNNER_NONPROD) { $runner = $env:NTIS_RUNNER_NONPROD }
Write-NtisOutput runner $runner

# ---- heads of every component repo ------------------------------------
$components = @()
foreach ($def in (Get-NtisComponent -Config $config)) {
    $repo = "$owner/$($def.repo)"
    $releases = @()
    if ($envDef.PSObject.Properties['releaseBranchPrefix']) { $releases = Get-NtisBranchNames -Repo $repo -Prefix $envDef.releaseBranchPrefix }
    $sourceRef = Select-NtisSourceRef -EnvironmentDefinition $envDef -ReleaseBranches $releases
    $head = Get-NtisRefHead -Repo $repo -Ref $sourceRef
    if (-not $head) { throw "Branch '$sourceRef' does not exist in $repo. Run scripts/setup/Initialize-EnvBranches.ps1 first." }

    $prHead = ''; $prTitle = ''
    $pr = Get-NtisMergedPullForCommit -Repo $repo -Sha $head.Sha
    if ($pr) { $prHead = [string]$pr.head.ref; $prTitle = [string]$pr.title }

    $components += [pscustomobject]@{
        Name = $def.name; Repo = $repo; SourceRef = $sourceRef; Sha = $head.Sha; Tree = $head.Tree; PrHead = $prHead; PrTitle = $prTitle
    }
}
Write-NtisOutput components (ConvertTo-Json @($components) -Compress -Depth 5)

# ---- promotion-set settling (design sec. 2.7) ------------------------------
$waiting = $false
if ($envDef.waitForPromotionSet -and -not $Force) {
    foreach ($c in $components) {
        $open = @(Get-NtisOpenPulls -Repo $c.Repo -Base $c.SourceRef -Label 'promotion')
        foreach ($p in $open) {
            Write-Host "Waiting: $($c.Repo)#$($p.number) '$($p.title)' into $($c.SourceRef) is still open."
            $waiting = $true
        }
    }
}
Write-NtisOutput waiting ($waiting.ToString().ToLowerInvariant())
if ($waiting) {
    Write-NtisSummary -Markdown "### ${EnvironmentKey}: waiting`nPromotion PRs into this environment are still open. The deploy runs when the last one merges."
}

# ---- what is live, what changed, what must be built --------------------
$current = Get-NtisBlobJson -Container $containers.State -Name "state/$EnvironmentKey/current.json"
$currentTrees = Get-NtisCurrentTrees $current
$changed = @(Get-NtisChangedComponents -Components $components -Current $currentTrees -Config $config)

$missing = @()
foreach ($c in $changed) {
    if (-not (Test-NtisBlob -Container $containers.Packages -Name (Get-NtisPackageBlobName -Component $c.Name -Tree $c.Tree -File 'metadata.json'))) {
        $missing += [pscustomobject]@{ repo = ($c.Repo -split '/')[-1]; sha = $c.Sha; tree = $c.Tree; component = $c.Name }
    }
}
$changedOut = @($changed | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Repo = $_.Repo; SourceRef = $_.SourceRef; Sha = $_.Sha; Tree = $_.Tree } })
Write-NtisOutput changed (ConvertTo-Json @($changedOut) -Compress -Depth 5)
Write-NtisOutput missing (ConvertTo-Json @($missing) -Compress -Depth 5)

# ---- tenants ------------------------------------------------------------
$tenantsFile = Join-Path $ConfigRoot 'tenants.json'
if (-not (Test-Path $tenantsFile)) { throw "tenants.json not found in $ConfigRoot" }
$tenants = @(Get-NtisTenantsForEnvironment -Tenants (Get-Content $tenantsFile -Raw | ConvertFrom-Json) -TenantEnvironment $envDef.tenantEnvironment)
if ($tenants.Count -eq 0) { Write-Warning "No tenants in tenants.json have environment '$($envDef.tenantEnvironment)'." }
Write-NtisOutput tenants (ConvertTo-Json @($tenants) -Compress)

# ---- release version (production) ----------------------------------------
$version = ''
if ($EnvironmentKey -eq 'production') {
    $trigger = $null
    if ($TriggerRepo) { $trigger = @($components | Where-Object { $_.Repo -eq $TriggerRepo }) | Select-Object -First 1 }
    $candidates = @()
    if ($trigger) { $candidates += $trigger }
    $candidates += @($components | Where-Object { -not $trigger -or $_.Repo -ne $trigger.Repo })
    foreach ($c in $candidates) {
        $v = Get-NtisVersionFromTitle $c.PrTitle
        if ($v) { $version = $v; break }
    }
    if (-not $version -and $changed.Count -gt 0) { Write-Warning 'No vX.Y.Z found in the merged PR titles; the release will not be tagged.' }
}
Write-NtisOutput version $version

# ---- summary ------------------------------------------------------------
$rows = @('| Component | Source | Commit | Tree | Live tree | Action |', '| --- | --- | --- | --- | --- | --- |')
foreach ($c in $components) {
    $live = ''; if ($currentTrees.ContainsKey($c.Name)) { $live = ([string]$currentTrees[$c.Name]).Substring(0, 10) }
    $action = 'unchanged'
    if (@($changed | ForEach-Object { $_.Name }) -contains $c.Name) {
        $action = 'deploy'
        if (@($missing | ForEach-Object { $_.component }) -contains $c.Name) { $action = 'build + deploy' }
    }
    $rows += "| $($c.Name) | ``$($c.SourceRef)`` | ``$($c.Sha.Substring(0,10))`` | ``$($c.Tree.Substring(0,10))`` | ``$live`` | $action |"
}
Write-NtisSummary -Markdown ("### $EnvironmentKey (" + $envDef.tenantEnvironment + " tenants: $($tenants.Count))`n" + ($rows -join "`n"))
exit 0
