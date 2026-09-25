#Requires -Version 5.1
<#
    NtisPipeline - orchestration logic for the NTIS CI/CD pipeline.

    Two halves:
      * Pure functions (no I/O)       - environment mapping, PR policy, promotion gates,
                                        component diffing, semver, config tokens. Unit tested.
      * Thin I/O wrappers             - GitHub (gh CLI) and Azure Blob (az CLI).

    Must stay compatible with Windows PowerShell 5.1 (the `powershell` shell on the runners):
    no ternary, no ??, no pipeline chain operators.
#>

Set-StrictMode -Version 2.0

$script:RepoRoot = Split-Path -Parent $PSScriptRoot

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# =====================================================================
# Configuration
# =====================================================================

function Get-NtisPipelineConfig {
    [CmdletBinding()]
    param([string] $Path = (Join-Path $script:RepoRoot 'config/environments.json'))
    if (-not (Test-Path $Path)) { throw "Pipeline config not found: $Path" }
    return (Get-Content $Path -Raw | ConvertFrom-Json)
}

function Get-NtisPrPolicy {
    [CmdletBinding()]
    param([string] $Path = (Join-Path $script:RepoRoot 'config/pr-policy.json'))
    if (-not (Test-Path $Path)) { throw "PR policy not found: $Path" }
    return (Get-Content $Path -Raw | ConvertFrom-Json)
}

function Get-NtisComponent {
    <# Returns component definitions sorted by deploy order (db -> platform -> ui). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config, [string] $Name, [string] $Repo)
    $all = @($Config.components | Sort-Object order)
    if ($Name) { return @($all | Where-Object { $_.name -eq $Name }) }
    if ($Repo) {
        $short = ($Repo -split '/')[-1]
        return @($all | Where-Object { $_.repo -eq $short })
    }
    return $all
}

# =====================================================================
# Environment mapping (design sec. 2.2)
# =====================================================================

function Resolve-NtisEnvironmentKey {
    <#
      Maps a branch of an app repo to an environment key (dev | qa | staging | production).
      release/* maps to staging. Returns $null for branches that do not deploy.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Ref, [Parameter(Mandatory)] $Config)

    $branch = $Ref -replace '^refs/heads/', ''
    foreach ($p in $Config.environments.PSObject.Properties) {
        $envDef = $p.Value
        if ($envDef.branch -eq $branch) { return $p.Name }
        $prefix = $null
        if ($envDef.PSObject.Properties['releaseBranchPrefix']) { $prefix = $envDef.releaseBranchPrefix }
        if ($prefix -and $branch.StartsWith($prefix)) { return $p.Name }
    }
    return $null
}

function Get-NtisEnvironment {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Key, [Parameter(Mandatory)] $Config)
    $prop = $Config.environments.PSObject.Properties[$Key]
    if (-not $prop) { throw "Unknown environment '$Key'. Known: $(@($Config.environments.PSObject.Properties.Name) -join ', ')" }
    return $prop.Value
}

function Select-NtisSourceRef {
    <#
      Chooses which branch of a repo feeds an environment.
      Staging takes the single active release/* branch when the repo has one (playbook sec. 4, design G3),
      otherwise the environment branch. More than one release/* is an error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $EnvironmentDefinition,
        [string[]] $ReleaseBranches = @()
    )
    $prefix = $null
    if ($EnvironmentDefinition.PSObject.Properties['releaseBranchPrefix']) { $prefix = $EnvironmentDefinition.releaseBranchPrefix }
    if (-not $prefix) { return $EnvironmentDefinition.branch }

    $releases = @($ReleaseBranches | Where-Object { $_ -and $_.StartsWith($prefix) })
    if ($releases.Count -gt 1) {
        throw "More than one release branch is open ($($releases -join ', ')). The playbook allows one active release at a time."
    }
    if ($releases.Count -eq 1) { return $releases[0] }
    return $EnvironmentDefinition.branch
}

function Get-NtisTenantsForEnvironment {
    <# Tenant URLs (keys of tenants.json) whose 'environment' equals the tenant environment, sorted. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Tenants, [Parameter(Mandatory)] [string] $TenantEnvironment)
    $urls = @()
    foreach ($p in $Tenants.PSObject.Properties) {
        if ($p.Name -like '$*') { continue }
        $cfg = $p.Value
        if ($cfg -and $cfg.PSObject.Properties['environment'] -and $cfg.environment -eq $TenantEnvironment) {
            $urls += $p.Name.ToLowerInvariant()
        }
    }
    return @($urls | Sort-Object)
}

# =====================================================================
# Versions (design D1: semver tags vX.Y.Z)
# =====================================================================

function ConvertTo-NtisSemVer {
    <# Parses 'v1.2.3' / '1.2.3' into [version]. Returns $null when not strict X.Y.Z. #>
    [CmdletBinding()]
    param([string] $Text)
    if (-not $Text) { return $null }
    $m = [regex]::Match($Text.Trim(), '^v?(\d+)\.(\d+)\.(\d+)$')
    if (-not $m.Success) { return $null }
    return New-Object System.Version ([int]$m.Groups[1].Value), ([int]$m.Groups[2].Value), ([int]$m.Groups[3].Value)
}

function Get-NtisVersionFromTitle {
    <# Extracts the first vX.Y.Z token from a PR title. #>
    [CmdletBinding()]
    param([string] $Title)
    if (-not $Title) { return $null }
    $m = [regex]::Match($Title, '(?<![\w.])v(\d+\.\d+\.\d+)(?![\w.])')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Get-NtisLatestSemVer {
    <# Highest vX.Y.Z among tag names, or $null. #>
    [CmdletBinding()]
    param([string[]] $Tags = @())
    $versions = @()
    foreach ($t in $Tags) {
        if ($t -match '^v\d+\.\d+\.\d+$') { $versions += (ConvertTo-NtisSemVer $t) }
    }
    if ($versions.Count -eq 0) { return $null }
    return ($versions | Sort-Object -Descending | Select-Object -First 1)
}

function Format-NtisSemVer {
    param([Parameter(Mandatory)] [version] $Version)
    return ('{0}.{1}.{2}' -f $Version.Major, $Version.Minor, $Version.Build)
}

# =====================================================================
# PR policy (design sec. 2.5)
# =====================================================================

function Test-NtisPrPolicy {
    <#
      Evaluates a pull request against config/pr-policy.json.

      -Facts (hashtable, gathered by the caller):
          LatestVersion     [version] or $null   highest vX.Y.Z tag in the repo
          ReleaseBranches   [string[]]           existing release/* branches in the repo
          OpenBackmerges    [hashtable]          base branch -> number of open PRs from backmerge/*

      Returns [pscustomobject] @{ Governed; Passed; Errors; Notes }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Base,
        [Parameter(Mandatory)] [string] $Head,
        [string] $Title = '',
        [Parameter(Mandatory)] $Policy,
        [hashtable] $Facts = @{}
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $notes = New-Object System.Collections.Generic.List[string]
    $ticket = $Policy.ticketPattern

    $rule = $null
    foreach ($t in $Policy.targets) {
        if ($Base -match $t.base) { $rule = $t; break }
    }
    if (-not $rule) {
        return [pscustomobject]@{ Governed = $false; Passed = $true; Errors = @(); Notes = @("Base '$Base' is not a governed branch.") }
    }

    # 1. Allowed source branch (sec. 3 promotion path, sec. 8 naming)
    $sourceOk = $false
    foreach ($s in $rule.sources) {
        $pattern = $s.Replace('{T}', $ticket)
        if ($Head -cmatch $pattern) { $sourceOk = $true; break }
    }
    if (-not $sourceOk) {
        $allowed = @($rule.sources | ForEach-Object { $_.Replace('{T}', '<TICKET>') }) -join ', '
        $errors.Add("Branch '$Head' may not merge into '$Base'. Allowed sources: $allowed.")
    }

    # 2. Ticket ID in the title (sec. 6)
    $exempt = $false
    foreach ($e in $Policy.ticketExemptHeads) { if ($Head -match $e) { $exempt = $true } }
    if (-not $exempt -and ($Title -notmatch $ticket)) {
        $errors.Add("PR title must reference a ticket ID matching $ticket (e.g. 'PROJ-214: Add OTP login').")
    }

    # 3. Release version in the title for PRs into main (sec. 3.3, sec. 5, D1)
    if ($rule.PSObject.Properties['requireVersion'] -and $rule.requireVersion) {
        $titleVersionText = Get-NtisVersionFromTitle $Title
        if (-not $titleVersionText) {
            $errors.Add("PRs into '$Base' must carry the release version in the title, e.g. 'REL-12: release v2.4.0'.")
        } else {
            $titleVersion = ConvertTo-NtisSemVer $titleVersionText
            $latest = $null
            if ($Facts.ContainsKey('LatestVersion')) { $latest = $Facts['LatestVersion'] }

            if ($latest -and $titleVersion -le $latest) {
                $errors.Add("Version v$titleVersionText must be greater than the latest release v$(Format-NtisSemVer $latest).")
            }
            if ($Head -like 'hotfix/*' -and $latest) {
                if ($titleVersion.Major -ne $latest.Major -or $titleVersion.Minor -ne $latest.Minor) {
                    $errors.Add("A hotfix must be a PATCH bump of v$(Format-NtisSemVer $latest) (same MAJOR.MINOR).")
                }
            }
            if ($Head -match '^release/(\d+\.\d+\.\d+)$') {
                if ($Matches[1] -ne $titleVersionText) {
                    $errors.Add("Title version v$titleVersionText does not match the release branch '$Head'.")
                }
            }
            $notes.Add("Release version: v$titleVersionText")
        }
    }

    # 4. Only one active release branch (sec. 4, design G3)
    if ($rule.PSObject.Properties['singleReleaseBranch'] -and $rule.singleReleaseBranch) {
        $releases = @()
        if ($Facts.ContainsKey('ReleaseBranches')) { $releases = @($Facts['ReleaseBranches']) }
        if ($releases.Count -gt 1) {
            $errors.Add("More than one release branch exists ($($releases -join ', ')). Finish or delete the older release first.")
        }
    }

    # 5. Pending back-merges must land before promoting further (sec. 5, sec. 7)
    if ($rule.PSObject.Properties['blockWhileBackmergeOpenInto'] -and $rule.blockWhileBackmergeOpenInto) {
        $into = $rule.blockWhileBackmergeOpenInto
        $open = 0
        if ($Facts.ContainsKey('OpenBackmerges') -and $Facts['OpenBackmerges'] -and $Facts['OpenBackmerges'].ContainsKey($into)) {
            $open = [int]$Facts['OpenBackmerges'][$into]
        }
        if ($open -gt 0) {
            $errors.Add("$open back-merge PR(s) into '$into' are still open. Merge them before promoting to '$Base'.")
        }
    }

    if ($rule.PSObject.Properties['mergeHint'] -and $rule.mergeHint) { $notes.Add("Merge method: $($rule.mergeHint)") }

    return [pscustomobject]@{
        Governed = $true
        Passed   = ($errors.Count -eq 0)
        Errors   = $errors.ToArray()
        Notes    = $notes.ToArray()
    }
}

# =====================================================================
# Promotion gate and diff (design sec. 2.7, sec. 2.8)
# =====================================================================

function Test-NtisPromotionGate {
    <#
      Decides whether each component's tree may be deployed to an environment.

      -Components : array of @{ Name; Tree; SourceRef; PrHead }
      -Current    : hashtable name -> tree currently live in THIS environment
      -LowerTrees : hashtable name -> string[] of every tree ever deployed to the lower environment
      -LowerCurrent : hashtable name -> tree currently live in the lower environment

      Rules:
        dev        always
        qa         always (trees never seen in dev are reported as notes)
        staging    tree seen in QA, or source is release/*, or merged via backmerge/*
        production tree equals Staging's live tree, or merged via hotfix/*
      A component whose tree is already live in the environment always passes (no-op).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EnvironmentKey,
        [Parameter(Mandatory)] [object[]] $Components,
        [hashtable] $Current = @{},
        [hashtable] $LowerTrees = @{},
        [hashtable] $LowerCurrent = @{}
    )

    $results = @()
    foreach ($c in $Components) {
        $name = $c.Name; $tree = $c.Tree
        $prHead = ''; if ($c.PrHead) { $prHead = [string]$c.PrHead }
        $sourceRef = ''; if ($c.SourceRef) { $sourceRef = [string]$c.SourceRef }
        $seenLower = $LowerTrees.ContainsKey($name) -and (@($LowerTrees[$name]) -contains $tree)
        $passed = $false; $reason = ''

        if ($Current.ContainsKey($name) -and $Current[$name] -eq $tree) {
            $passed = $true; $reason = 'unchanged'
        } else {
            switch ($EnvironmentKey) {
                'dev' { $passed = $true; $reason = 'dev accepts every tree' }
                'qa' {
                    $passed = $true
                    if ($seenLower) { $reason = 'tested in dev' } else { $reason = 'new tree (not previously deployed to dev)' }
                }
                'staging' {
                    if ($seenLower) { $passed = $true; $reason = 'tested in QA' }
                    elseif ($sourceRef -like 'release/*') { $passed = $true; $reason = "release branch $sourceRef (playbook sec. 4)" }
                    elseif ($prHead -like 'backmerge/*') { $passed = $true; $reason = "back-merge $prHead" }
                    else { $reason = "tree $($tree.Substring(0,[Math]::Min(12,$tree.Length))) was never deployed to QA - promote it through qa first" }
                }
                'production' {
                    $lower = $null
                    if ($LowerCurrent.ContainsKey($name)) { $lower = $LowerCurrent[$name] }
                    if ($lower -and $lower -eq $tree) { $passed = $true; $reason = 'identical to Staging' }
                    elseif ($prHead -like 'hotfix/*') { $passed = $true; $reason = "hotfix $prHead (playbook sec. 5)" }
                    else { $reason = 'production must run exactly what Staging runs; this tree differs from Staging' }
                }
                default { throw "Unknown environment '$EnvironmentKey'" }
            }
        }
        $results += [pscustomobject]@{ Name = $name; Tree = $tree; Passed = $passed; Reason = $reason }
    }
    return $results
}

function Get-NtisChangedComponents {
    <# Components whose tree differs from what is live, in deploy order (db -> platform -> ui). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Components,
        [hashtable] $Current = @{},
        [Parameter(Mandatory)] $Config
    )
    $order = @{}
    foreach ($d in $Config.components) { $order[$d.name] = [int]$d.order }
    $changed = @($Components | Where-Object { -not ($Current.ContainsKey($_.Name) -and $Current[$_.Name] -eq $_.Tree) })
    return @($changed | Sort-Object { $order[$_.Name] })
}

function ConvertTo-NtisHashtable {
    <# Converts a flat PSCustomObject (from JSON) into a hashtable. #>
    param($InputObject)
    $h = @{}
    if ($null -eq $InputObject) { return $h }
    foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = $p.Value }
    return $h
}

function Get-NtisCurrentTrees {
    <# From a state/<env>/current.json object -> hashtable component -> tree. #>
    param($State)
    $h = @{}
    if ($null -eq $State -or -not $State.PSObject.Properties['components']) { return $h }
    foreach ($p in $State.components.PSObject.Properties) { $h[$p.Name] = $p.Value.tree }
    return $h
}

function Merge-NtisTreeIndex {
    <# Adds deployed trees to the per-environment index (component -> distinct trees). #>
    [CmdletBinding()]
    param($Index, [Parameter(Mandatory)] [object[]] $Components)
    $h = @{}
    if ($Index) { foreach ($p in $Index.PSObject.Properties) { $h[$p.Name] = @($p.Value) } }
    foreach ($c in $Components) {
        if (-not $h.ContainsKey($c.Name)) { $h[$c.Name] = @() }
        if (@($h[$c.Name]) -notcontains $c.Tree) { $h[$c.Name] = @($h[$c.Name]) + $c.Tree }
    }
    return $h
}

function New-NtisEnvironmentState {
    <#
      Builds the new state/<env>/current.json after a deploy: previous components overlaid with
      the ones just deployed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EnvironmentKey,
        $Previous,
        [Parameter(Mandatory)] [object[]] $Deployed,
        [string] $Version,
        [string] $RunUrl,
        [string] $Actor
    )
    $components = [ordered]@{}
    if ($Previous -and $Previous.PSObject.Properties['components']) {
        foreach ($p in $Previous.components.PSObject.Properties) { $components[$p.Name] = $p.Value }
    }
    foreach ($d in $Deployed) {
        $components[$d.Name] = [ordered]@{
            repo      = $d.Repo
            ref       = $d.SourceRef
            commitSha = $d.Sha
            tree      = $d.Tree
        }
    }
    return [ordered]@{
        environment = $EnvironmentKey
        version     = $Version
        deployedAt  = (Get-Date).ToUniversalTime().ToString('o')
        runUrl      = $RunUrl
        actor       = $Actor
        components  = $components
    }
}

# =====================================================================
# Config tokens (design sec. 2.9 step 7)
# =====================================================================

function Expand-NtisConfigTokens {
    <#
      Replaces #{NAME}# tokens with values from -Secrets (hashtable). Throws when a token has no value,
      so a half-configured file is never deployed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text, [hashtable] $Secrets = @{}, [string] $Source = 'config')
    $missing = New-Object System.Collections.Generic.List[string]
    $result = [regex]::Replace($Text, '#\{([A-Za-z0-9_]+)\}#', {
            param($m)
            $key = $m.Groups[1].Value
            if ($Secrets.ContainsKey($key) -and $null -ne $Secrets[$key]) { return [string]$Secrets[$key] }
            $missing.Add($key) | Out-Null
            return $m.Value
        })
    if ($missing.Count -gt 0) {
        throw "Unresolved config tokens in ${Source}: $((@($missing) | Sort-Object -Unique) -join ', '). Add them as environment secrets."
    }
    return $result
}

# =====================================================================
# GitHub wrappers (gh CLI; token from GH_TOKEN)
# =====================================================================

function Invoke-NtisGh {
    <# Runs gh and returns stdout text. Throws with stderr on failure unless -AllowNotFound and 404. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string[]] $Arguments, [switch] $AllowNotFound)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & gh @Arguments 2>&1
        $code = $LASTEXITCODE
        $global:LASTEXITCODE = 0
    } finally { $ErrorActionPreference = $prev }
    $out = @($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    $err = @($raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() }) -join "`n"
    if ($code -ne 0) {
        if ($AllowNotFound -and ($err -match 'HTTP 404|Not Found')) { return $null }
        throw "gh $($Arguments -join ' ') failed ($code): $err $out"
    }
    return $out
}

function Invoke-NtisGhJson {
    param([Parameter(Mandatory)] [string] $Path, [switch] $AllowNotFound)
    $out = Invoke-NtisGh -Arguments @('api', $Path) -AllowNotFound:$AllowNotFound
    if ($null -eq $out -or $out -eq '') { return $null }
    return ($out | ConvertFrom-Json)
}

function Invoke-NtisGhList {
    <# Paginated list endpoint -> array of objects (one JSON object per line via --jq). #>
    param([Parameter(Mandatory)] [string] $Path)
    $out = Invoke-NtisGh -Arguments @('api', '--paginate', $Path, '--jq', '.[]')
    if (-not $out) { return @() }
    return @($out -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}

function Invoke-NtisGhWrite {
    <# POST/PATCH/PUT a JSON body to the GitHub API; returns the parsed response. #>
    param([Parameter(Mandatory)] [ValidateSet('POST', 'PATCH', 'PUT', 'DELETE')] [string] $Method, [Parameter(Mandatory)] [string] $Path, $Body)
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        $json = '{}'
        if ($null -ne $Body) { $json = $Body | ConvertTo-Json -Depth 20 }
        [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding $false))
        $out = Invoke-NtisGh -Arguments @('api', '-X', $Method, $Path, '--input', $tmp)
        if ($out) { return ($out | ConvertFrom-Json) }
        return $null
    } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

function Test-NtisBranchContains {
    <# $true when every change on -Head is already in -Base (no files differ between base...head). #>
    param([Parameter(Mandatory)] [string] $Repo, [Parameter(Mandatory)] [string] $Base, [Parameter(Mandatory)] [string] $Head)
    $cmp = Invoke-NtisGhJson -Path "repos/$Repo/compare/$Base...$Head"
    return (@($cmp.files).Count -eq 0)
}

function Initialize-NtisLabel {
    param([Parameter(Mandatory)] [string] $Repo, [Parameter(Mandatory)] [string] $Name, [string] $Color = '5319e7', [string] $Description = '')
    $existing = Invoke-NtisGhJson -Path "repos/$Repo/labels/$Name" -AllowNotFound
    if (-not $existing) { Invoke-NtisGhWrite -Method POST -Path "repos/$Repo/labels" -Body @{ name = $Name; color = $Color; description = $Description } | Out-Null }
}

function Get-NtisRefHead {
    <# Commit SHA and tree SHA at a branch. $null when the branch does not exist. #>
    param([Parameter(Mandatory)] [string] $Repo, [Parameter(Mandatory)] [string] $Ref)
    # The branches endpoint answers 404 for a missing branch (the commits endpoint answers 422).
    $b = Invoke-NtisGhJson -Path "repos/$Repo/branches/$Ref" -AllowNotFound
    if (-not $b) { return $null }
    return [pscustomobject]@{ Sha = $b.commit.sha; Tree = $b.commit.commit.tree.sha }
}

function Get-NtisBranchNames {
    param([Parameter(Mandatory)] [string] $Repo, [string] $Prefix = '')
    $matching = Invoke-NtisGhList -Path "repos/$Repo/git/matching-refs/heads/$Prefix"
    return @($matching | ForEach-Object { $_.ref -replace '^refs/heads/', '' })
}

function Get-NtisTagNames {
    param([Parameter(Mandatory)] [string] $Repo)
    $matching = Invoke-NtisGhList -Path "repos/$Repo/git/matching-refs/tags/v"
    return @($matching | ForEach-Object { $_.ref -replace '^refs/tags/', '' })
}

function Get-NtisOpenPulls {
    param([Parameter(Mandatory)] [string] $Repo, [string] $Base, [string] $Label)
    $path = "repos/$Repo/pulls?state=open&per_page=100"
    if ($Base) { $path += "&base=$([uri]::EscapeDataString($Base))" }
    $pulls = Invoke-NtisGhList -Path $path
    if ($Label) { $pulls = @($pulls | Where-Object { @($_.labels | ForEach-Object { $_.name }) -contains $Label }) }
    return @($pulls)
}

function Get-NtisMergedPullForCommit {
    <# The merged PR that produced a commit (for gate exceptions and release versions). #>
    param([Parameter(Mandatory)] [string] $Repo, [Parameter(Mandatory)] [string] $Sha)
    $pulls = Invoke-NtisGhList -Path "repos/$Repo/commits/$Sha/pulls"
    $merged = @($pulls | Where-Object { $_.merged_at -and $_.merge_commit_sha -eq $Sha })
    if ($merged.Count -gt 0) { return $merged[0] }
    return $null
}

function Write-NtisOutput {
    <# Writes a step output (single line; JSON is compressed). #>
    param([Parameter(Mandatory)] [string] $Name, [AllowEmptyString()] [string] $Value)
    if ($env:GITHUB_OUTPUT) {
        [System.IO.File]::AppendAllText($env:GITHUB_OUTPUT, "$Name=$Value`n", (New-Object System.Text.UTF8Encoding $false))
    }
    Write-Host "output $Name=$Value"
}

function Write-NtisSummary {
    param([Parameter(Mandatory)] [string] $Markdown)
    if ($env:GITHUB_STEP_SUMMARY) {
        [System.IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, "$Markdown`n", (New-Object System.Text.UTF8Encoding $false))
    } else { Write-Host $Markdown }
}

# =====================================================================
# Azure Blob wrappers (az CLI; credentials from AZURE_STORAGE_CONNECTION_STRING)
# =====================================================================

function Invoke-NtisAz {
    param([Parameter(Mandatory)] [string[]] $Arguments)
    if (-not $env:AZURE_STORAGE_CONNECTION_STRING) { throw 'AZURE_STORAGE_CONNECTION_STRING is not set.' }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & az @Arguments --only-show-errors 2>&1
        $code = $LASTEXITCODE
        $global:LASTEXITCODE = 0
    } finally { $ErrorActionPreference = $prev }
    $out = @($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    $err = @($raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() }) -join "`n"
    if ($code -ne 0) { throw "az $($Arguments[0..2] -join ' ') failed ($code): $err" }
    return $out
}

function Test-NtisBlob {
    param([Parameter(Mandatory)] [string] $Container, [Parameter(Mandatory)] [string] $Name)
    $r = Invoke-NtisAz -Arguments @('storage', 'blob', 'exists', '--container-name', $Container, '--name', $Name, '--query', 'exists', '--output', 'tsv')
    return ($r.Trim() -eq 'true')
}

function Save-NtisBlobFile {
    param([Parameter(Mandatory)] [string] $Container, [Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [string] $Path)
    Invoke-NtisAz -Arguments @('storage', 'blob', 'download', '--container-name', $Container, '--name', $Name, '--file', $Path, '--overwrite') | Out-Null
}

function Publish-NtisBlobFile {
    <# Uploads a file. Without -Overwrite an existing blob is an error (immutable packages, F13). #>
    param([Parameter(Mandatory)] [string] $Container, [Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [string] $Path, [switch] $Overwrite)
    $azArgs = @('storage', 'blob', 'upload', '--container-name', $Container, '--name', $Name, '--file', $Path)
    if ($Overwrite) { $azArgs += '--overwrite' }
    Invoke-NtisAz -Arguments $azArgs | Out-Null
}

function Get-NtisBlobJson {
    <# Reads a JSON blob, or $null when it does not exist. #>
    param([Parameter(Mandatory)] [string] $Container, [Parameter(Mandatory)] [string] $Name)
    if (-not (Test-NtisBlob -Container $Container -Name $Name)) { return $null }
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        Save-NtisBlobFile -Container $Container -Name $Name -Path $tmp
        return (Get-Content $tmp -Raw -Encoding UTF8 | ConvertFrom-Json)
    } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

function Set-NtisBlobJson {
    param([Parameter(Mandatory)] [string] $Container, [Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] $Value)
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        $json = $Value | ConvertTo-Json -Depth 20
        [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding $false))
        Publish-NtisBlobFile -Container $Container -Name $Name -Path $tmp -Overwrite
    } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

function Get-NtisPackageBlobName {
    param([Parameter(Mandatory)] [string] $Component, [Parameter(Mandatory)] [string] $Tree, [string] $File)
    if (-not $File) { $File = "$Component.zip" }
    return "packages/$Component/$Tree/$File"
}

function Get-NtisContainerNames {
    $pkg = 'ntis-packages'; $state = 'ntis-state'
    if ($env:NTIS_PACKAGE_CONTAINER) { $pkg = $env:NTIS_PACKAGE_CONTAINER }
    if ($env:NTIS_STATE_CONTAINER) { $state = $env:NTIS_STATE_CONTAINER }
    return [pscustomobject]@{ Packages = $pkg; State = $state }
}

Export-ModuleMember -Function *-Ntis*
