<#
.SYNOPSIS
    Deploys the changed components to ONE tenant, as one transaction with automatic rollback (design sec. 2.9).
.DESCRIPTION
    Downloads packages by tree from Blob, verifies SHA-256 against metadata.json, extracts them into a
    per-run folder (no shared C:\Deploy - F17/F18) and calls Invoke-NtisTenantDeploy.
    Env: AZURE_STORAGE_CONNECTION_STRING, SECRETS_JSON (toJSON(secrets) of the environment, for #{TOKEN}# config).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $TenantUrl,
    [Parameter(Mandatory)] [string] $EnvironmentKey,
    [Parameter(Mandatory)] [string] $ComponentsJson,
    [Parameter(Mandatory)] [string] $ConfigRoot,
    [string] $WorkRoot = (Join-Path $env:RUNNER_TEMP 'ntis-deploy'),
    [string] $Version = '',
    [string] $RunUrl = '',
    [string] $BackupRoot = $env:BACKUP_ROOT,
    [switch] $SkipHealthCheck
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'NtisPipeline.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'NtisDeploy.psm1') -Force -DisableNameChecking

$config = Get-NtisPipelineConfig
$envDef = Get-NtisEnvironment -Key $EnvironmentKey -Config $config
$deployConfig = Get-NtisDeployConfig
$containers = Get-NtisContainerNames

$tenant = Get-NtisTenant -TenantsFile (Join-Path $ConfigRoot 'tenants.json') -Url $TenantUrl
$components = @($ComponentsJson | ConvertFrom-Json)
if ($components.Count -eq 0) { Write-Host 'No components to deploy.'; exit 0 }

$secrets = @{}
if ($env:SECRETS_JSON) { $secrets = ConvertTo-NtisHashtable ($env:SECRETS_JSON | ConvertFrom-Json) }

$work = Join-Path $WorkRoot ("{0}-{1}" -f $env:GITHUB_RUN_ID, $tenant.Tenant)
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Path $work -Force | Out-Null

try {
    $packages = @{}
    foreach ($c in $components) {
        $zip = Join-Path $work "$($c.Name).zip"
        $meta = Join-Path $work "$($c.Name).metadata.json"
        Write-Host "Downloading $($c.Name) tree $($c.Tree)"
        Save-NtisBlobFile -Container $containers.Packages -Name (Get-NtisPackageBlobName -Component $c.Name -Tree $c.Tree) -Path $zip
        Save-NtisBlobFile -Container $containers.Packages -Name (Get-NtisPackageBlobName -Component $c.Name -Tree $c.Tree -File 'metadata.json') -Path $meta
        $expected = (Get-Content $meta -Raw | ConvertFrom-Json).sha256
        $actual = (Get-FileHash -Path $zip -Algorithm SHA256).Hash
        if ($expected -and $expected -ne $actual) { throw "Checksum mismatch for $($c.Name): expected $expected, got $actual." }
        $packages[$c.Name] = Expand-NtisPackage -Zip $zip -Destination (Join-Path $work $c.Name)
    }

    $componentStamp = @{}
    foreach ($c in $components) { $componentStamp[$c.Name] = @{ repo = $c.Repo; ref = $c.SourceRef; commitSha = $c.Sha; tree = $c.Tree } }
    $stamp = @{
        version     = $Version
        environment = $EnvironmentKey
        tenant      = $tenant.Url
        deployedAt  = (Get-Date).ToUniversalTime().ToString('o')
        runUrl      = $RunUrl
        components  = $componentStamp
    }

    $backup = Invoke-NtisTenantDeploy -Tenant $tenant -TenantEnvironment $envDef.tenantEnvironment `
        -Components @($components | ForEach-Object { $_.Name }) -Packages $packages -ConfigRoot $ConfigRoot `
        -DeployConfig $deployConfig -Secrets $secrets -Stamp $stamp -BackupRoot $BackupRoot -SkipHealthCheck:$SkipHealthCheck

    Write-NtisSummary -Markdown "Deployed $(@($components | ForEach-Object { $_.Name }) -join ', ') to **$($tenant.Url)** (backup: ``$backup``)."
} finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
exit 0
