<#
.SYNOPSIS
    Zips a built component and uploads it by git tree: packages/<component>/<tree>/<component>.zip + metadata.json.
    Idempotent and immutable (F13): an existing package is never overwritten.
    Env: AZURE_STORAGE_CONNECTION_STRING.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Component,
    [Parameter(Mandatory)] [string] $Tree,
    [Parameter(Mandatory)] [string] $Sha,
    [Parameter(Mandatory)] [string] $Repo,
    [Parameter(Mandatory)] [string] $PackageDir,
    [string] $RunUrl = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'NtisPipeline.psm1') -Force -DisableNameChecking
$containers = Get-NtisContainerNames
$zipBlob = Get-NtisPackageBlobName -Component $Component -Tree $Tree
$metaBlob = Get-NtisPackageBlobName -Component $Component -Tree $Tree -File 'metadata.json'

# A package is complete when metadata.json exists (it is written last).
if (Test-NtisBlob -Container $containers.Packages -Name $metaBlob) {
    Write-Host "Package $zipBlob already exists; reusing it."
    exit 0
}
if (Test-NtisBlob -Container $containers.Packages -Name $zipBlob) {
    # Zip landed but the run died before metadata: describe the existing (immutable) zip instead of rebuilding.
    Write-Warning "Found $zipBlob without metadata; writing metadata for the existing zip."
    $existing = Join-Path ([System.IO.Path]::GetTempPath()) ("$Component-$Tree.existing.zip")
    Save-NtisBlobFile -Container $containers.Packages -Name $zipBlob -Path $existing
    $metaFile = Join-Path ([System.IO.Path]::GetTempPath()) ("$Component-$Tree.metadata.json")
    [ordered]@{
        component = $Component; repo = $Repo; commitSha = $Sha; tree = $Tree
        sha256 = (Get-FileHash $existing -Algorithm SHA256).Hash; sizeMb = [math]::Round((Get-Item $existing).Length / 1MB, 1)
        builtAt = $null; runUrl = $RunUrl; note = 'metadata recovered after an interrupted upload'
    } | ConvertTo-Json | Set-Content -Path $metaFile -Encoding UTF8
    Publish-NtisBlobFile -Container $containers.Packages -Name $metaBlob -Path $metaFile
    Remove-Item $existing, $metaFile -Force -ErrorAction SilentlyContinue
    exit 0
}
if (-not (Test-Path $PackageDir) -or -not (Get-ChildItem $PackageDir -Recurse -File | Select-Object -First 1)) {
    throw "Package folder $PackageDir is empty."
}

# Build stamp inside the package (F15)
@{ component = $Component; repo = $Repo; commitSha = $Sha; tree = $Tree; builtAt = (Get-Date).ToUniversalTime().ToString('o'); runUrl = $RunUrl } |
    ConvertTo-Json | Set-Content -Path (Join-Path $PackageDir 'build.json') -Encoding UTF8

$zip = Join-Path ([System.IO.Path]::GetTempPath()) ("$Component-$Tree.zip")
if (Test-Path $zip) { Remove-Item $zip -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory((Resolve-Path $PackageDir).Path, $zip, [System.IO.Compression.CompressionLevel]::Optimal, $false)
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash
$sizeMb = [math]::Round((Get-Item $zip).Length / 1MB, 1)

$metaFile = Join-Path ([System.IO.Path]::GetTempPath()) ("$Component-$Tree.metadata.json")
[ordered]@{
    component = $Component; repo = $Repo; commitSha = $Sha; tree = $Tree
    sha256 = $hash; sizeMb = $sizeMb; builtAt = (Get-Date).ToUniversalTime().ToString('o'); runUrl = $RunUrl
} | ConvertTo-Json | Set-Content -Path $metaFile -Encoding UTF8

try {
    # zip first, metadata last: metadata.json marks the package complete
    Publish-NtisBlobFile -Container $containers.Packages -Name $zipBlob -Path $zip
    Publish-NtisBlobFile -Container $containers.Packages -Name $metaBlob -Path $metaFile
} catch {
    if (Test-NtisBlob -Container $containers.Packages -Name $metaBlob) {
        Write-Warning "Another run uploaded $zipBlob concurrently; reusing it."
    } else { throw }
} finally {
    Remove-Item $zip, $metaFile -Force -ErrorAction SilentlyContinue
}
Write-NtisSummary -Markdown "Built **$Component** from ``$Repo@$($Sha.Substring(0,10))`` -> ``$zipBlob`` ($sizeMb MB, sha256 ``$($hash.Substring(0,12))``)."
exit 0
