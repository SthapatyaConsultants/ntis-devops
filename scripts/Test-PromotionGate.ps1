<#
.SYNOPSIS
    Promotion gate (design sec. 2.8): Staging only takes trees QA has run; Production only takes what Staging runs
    (hotfix/* excepted). Fails the job with a per-component reason.
    Env: AZURE_STORAGE_CONNECTION_STRING.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EnvironmentKey,
    [Parameter(Mandatory)] [string] $ComponentsJson
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'NtisPipeline.psm1') -Force -DisableNameChecking

$config = Get-NtisPipelineConfig
$envDef = Get-NtisEnvironment -Key $EnvironmentKey -Config $config
$containers = Get-NtisContainerNames

$components = @($ComponentsJson | ConvertFrom-Json | ForEach-Object {
        @{ Name = $_.Name; Tree = $_.Tree; SourceRef = $_.SourceRef; PrHead = $_.PrHead }
    })

$current = Get-NtisCurrentTrees (Get-NtisBlobJson -Container $containers.State -Name "state/$EnvironmentKey/current.json")
$lowerTrees = @{}
$lowerCurrent = @{}
if ($envDef.lowerEnvironment) {
    $lowerTrees = ConvertTo-NtisHashtable (Get-NtisBlobJson -Container $containers.State -Name "state/$($envDef.lowerEnvironment)/trees.json")
    $lowerCurrent = Get-NtisCurrentTrees (Get-NtisBlobJson -Container $containers.State -Name "state/$($envDef.lowerEnvironment)/current.json")
}

$results = @(Test-NtisPromotionGate -EnvironmentKey $EnvironmentKey -Components $components -Current $current -LowerTrees $lowerTrees -LowerCurrent $lowerCurrent)

$rows = @('| Component | Tree | Gate | Reason |', '| --- | --- | --- | --- |')
foreach ($r in $results) {
    $mark = 'pass'; if (-not $r.Passed) { $mark = '**FAIL**' }
    $rows += "| $($r.Name) | ``$($r.Tree.Substring(0,10))`` | $mark | $($r.Reason) |"
}
Write-NtisSummary -Markdown ("### Promotion gate: $EnvironmentKey`n" + ($rows -join "`n"))

$failed = @($results | Where-Object { -not $_.Passed })
if ($failed.Count -gt 0) {
    foreach ($f in $failed) { Write-Host "::error title=Promotion gate ($EnvironmentKey)::$($f.Name): $($f.Reason)" }
    exit 1
}
Write-Host "Promotion gate passed for $EnvironmentKey."
exit 0
