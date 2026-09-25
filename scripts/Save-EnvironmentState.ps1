<#
.SYNOPSIS
    Records what an environment now runs: state/<env>/current.json, state/<env>/history/<ts>.json and the
    tree index state/<env>/trees.json used by the next stage's promotion gate.
    Env: AZURE_STORAGE_CONNECTION_STRING.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EnvironmentKey,
    [Parameter(Mandatory)] [string] $ChangedJson,
    [string] $Version = '',
    [string] $RunUrl = '',
    [string] $Actor = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'NtisPipeline.psm1') -Force -DisableNameChecking
$containers = Get-NtisContainerNames

$deployed = @($ChangedJson | ConvertFrom-Json)
if ($deployed.Count -eq 0) { Write-Host 'Nothing was deployed; state unchanged.'; exit 0 }

$previous = Get-NtisBlobJson -Container $containers.State -Name "state/$EnvironmentKey/current.json"
$state = New-NtisEnvironmentState -EnvironmentKey $EnvironmentKey -Previous $previous -Deployed $deployed -Version $Version -RunUrl $RunUrl -Actor $Actor
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')

Set-NtisBlobJson -Container $containers.State -Name "state/$EnvironmentKey/current.json" -Value $state
Set-NtisBlobJson -Container $containers.State -Name "state/$EnvironmentKey/history/$stamp.json" -Value $state

$index = Get-NtisBlobJson -Container $containers.State -Name "state/$EnvironmentKey/trees.json"
$merged = Merge-NtisTreeIndex -Index $index -Components @($deployed | ForEach-Object { @{ Name = $_.Name; Tree = $_.Tree } })
Set-NtisBlobJson -Container $containers.State -Name "state/$EnvironmentKey/trees.json" -Value $merged

Write-NtisOutput history_file "state/$EnvironmentKey/history/$stamp.json"
Write-NtisSummary -Markdown "Recorded ``state/$EnvironmentKey/current.json`` ($(@($deployed | ForEach-Object { $_.Name }) -join ', '))."
exit 0
