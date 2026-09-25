<#
.SYNOPSIS
    Works out which component trees a rollback should deploy (design sec. 2.12).
    -Target: 'previous'                -> the history entry before the current one
             'vX.Y.Z'                  -> releases/vX.Y.Z.json (production releases)
             '<yyyyMMddHHmmss>'        -> state/<env>/history/<stamp>.json
    Outputs: changed (JSON, only components that differ from what is live), tenants, runner, github_environment,
             tenant_environment, version.
    Env: AZURE_STORAGE_CONNECTION_STRING.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EnvironmentKey,
    [Parameter(Mandatory)] [string] $Target,
    [Parameter(Mandatory)] [string] $ConfigRoot,
    [string] $Tenant = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'NtisPipeline.psm1') -Force -DisableNameChecking
$config = Get-NtisPipelineConfig
$envDef = Get-NtisEnvironment -Key $EnvironmentKey -Config $config
$containers = Get-NtisContainerNames

$current = Get-NtisBlobJson -Container $containers.State -Name "state/$EnvironmentKey/current.json"
if ($Target -match '^v\d+\.\d+\.\d+$') {
    $source = Get-NtisBlobJson -Container $containers.State -Name "releases/$Target.json"
    if (-not $source) { throw "No release manifest releases/$Target.json." }
} else {
    $names = @(Invoke-NtisAz -Arguments @('storage', 'blob', 'list', '--container-name', $containers.State, '--prefix', "state/$EnvironmentKey/history/", '--query', '[].name', '--output', 'tsv') -split "`n" |
            Where-Object { $_.Trim() } | Sort-Object -Descending)
    if ($Target -eq 'previous') {
        if ($names.Count -lt 2) { throw "No previous deployment recorded for $EnvironmentKey." }
        $pick = $names[1]
    } else {
        $pick = "state/$EnvironmentKey/history/$Target.json"
        if ($names -notcontains $pick) { throw "History entry $pick not found." }
    }
    $source = Get-NtisBlobJson -Container $containers.State -Name $pick
}

$components = @()
foreach ($p in $source.components.PSObject.Properties) {
    $components += [pscustomobject]@{ Name = $p.Name; Repo = $p.Value.repo; SourceRef = $p.Value.ref; Sha = $p.Value.commitSha; Tree = $p.Value.tree }
}
$changed = @(Get-NtisChangedComponents -Components $components -Current (Get-NtisCurrentTrees $current) -Config $config)
foreach ($c in $changed) {
    if (-not (Test-NtisBlob -Container $containers.Packages -Name (Get-NtisPackageBlobName -Component $c.Name -Tree $c.Tree))) {
        throw "Package for $($c.Name) tree $($c.Tree) no longer exists; cannot roll back to $Target."
    }
}

$tenants = @(Get-NtisTenantsForEnvironment -Tenants (Get-Content (Join-Path $ConfigRoot 'tenants.json') -Raw | ConvertFrom-Json) -TenantEnvironment $envDef.tenantEnvironment)
if ($Tenant) {
    if ($tenants -notcontains $Tenant.ToLowerInvariant()) { throw "Tenant $Tenant is not a $($envDef.tenantEnvironment) tenant." }
    $tenants = @($Tenant.ToLowerInvariant())
}

$runner = 'ntis-deploy-nonprod'
if ($envDef.runnerClass -eq 'prod') { $runner = 'ntis-deploy-prod'; if ($env:NTIS_RUNNER_PROD) { $runner = $env:NTIS_RUNNER_PROD } }
elseif ($env:NTIS_RUNNER_NONPROD) { $runner = $env:NTIS_RUNNER_NONPROD }

$version = ''
if ($source.PSObject.Properties['version'] -and $source.version) { $version = [string]$source.version }

Write-NtisOutput changed (ConvertTo-Json @($changed) -Compress -Depth 5)
Write-NtisOutput tenants (ConvertTo-Json @($tenants) -Compress)
Write-NtisOutput runner $runner
Write-NtisOutput github_environment $envDef.githubEnvironment
Write-NtisOutput version $version
Write-NtisSummary -Markdown "### Rollback $EnvironmentKey -> $Target`nComponents: $(@($changed | ForEach-Object { $_.Name }) -join ', ')`nTenants: $($tenants -join ', ')"
exit 0
