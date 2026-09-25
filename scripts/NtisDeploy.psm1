#Requires -Version 5.1
<#
    NtisDeploy - runs on the deploy runner (the IIS host). Deploys one tenant as a single transaction:

      preflight -> backup -> stop -> migrate -> publish -> config -> stamp -> start -> health
                         \______________ on any failure: restore backup + start ______________/

    Windows PowerShell 5.1 compatible (WebAdministration). Every external effect sits behind a small
    function so the transaction logic in Invoke-NtisTenantDeploy can be unit tested with mocks.
#>

Set-StrictMode -Version 2.0

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'NtisPipeline.psm1') -Force -DisableNameChecking

function Get-NtisDeployConfig {
    param([string] $Path = (Join-Path $script:RepoRoot 'config/deploy.json'))
    return (Get-Content $Path -Raw | ConvertFrom-Json)
}

# =====================================================================
# Tenant definition
# =====================================================================

function Get-NtisTenant {
    <#
      Loads one tenant from ntis-configs/tenants.json (keyed by URL) and validates it.
      Required: environment, tenant, apiSite, apiPath, uiPath, uiService.
      Optional: workerPath, workerService, uiHealthUrl, apiHealthUrl, preserveFiles, migrateDatabase (default true),
                applyConfig (default false - set true once the tenant's config inventory in ntis-configs is complete, plan task 4.2).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $TenantsFile, [Parameter(Mandatory)] [string] $Url)

    if (-not (Test-Path $TenantsFile)) { throw "tenants.json not found at $TenantsFile" }
    $all = Get-Content $TenantsFile -Raw | ConvertFrom-Json
    $key = $Url.Trim().ToLowerInvariant()
    if ($key -notmatch '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$') { throw "Invalid tenant URL '$Url'." }

    $prop = $all.PSObject.Properties | Where-Object { $_.Name.ToLowerInvariant() -eq $key } | Select-Object -First 1
    if (-not $prop) { throw "No tenant configured for URL '$key' in tenants.json." }
    $cfg = $prop.Value

    foreach ($f in 'environment', 'tenant', 'apiSite', 'apiPath', 'uiPath', 'uiService') {
        if (-not $cfg.PSObject.Properties[$f] -or -not [string]$cfg.$f) { throw "Tenant '$key' is missing '$f' in tenants.json." }
    }
    foreach ($f in 'apiPath', 'uiPath') {
        if ([string]$cfg.$f -notmatch '^[A-Za-z]:\\') { throw "Tenant '$key': $f must be an absolute Windows path." }
    }

    $opt = { param($name, $default) if ($cfg.PSObject.Properties[$name] -and $null -ne $cfg.$name -and [string]$cfg.$name -ne '') { $cfg.$name } else { $default } }
    $migrateDb = $true
    if ($cfg.PSObject.Properties['migrateDatabase'] -and $cfg.migrateDatabase -is [bool]) { $migrateDb = $cfg.migrateDatabase }
    $applyConfig = $false
    if ($cfg.PSObject.Properties['applyConfig'] -and $cfg.applyConfig -is [bool]) { $applyConfig = $cfg.applyConfig }
    return [pscustomobject]@{
        Url             = $key
        Environment     = [string]$cfg.environment
        Tenant          = [string]$cfg.tenant
        ApiSite         = [string]$cfg.apiSite
        ApiPath         = [string]$cfg.apiPath
        UiPath          = [string]$cfg.uiPath
        UiService       = [string]$cfg.uiService
        WorkerPath      = [string](& $opt 'workerPath' '')
        WorkerService   = [string](& $opt 'workerService' '')
        UiHealthUrl     = [string](& $opt 'uiHealthUrl' "https://$key/")
        ApiHealthUrl    = [string](& $opt 'apiHealthUrl' '')
        PreserveFiles   = @(& $opt 'preserveFiles' @())
        MigrateDatabase = $migrateDb
        ApplyConfig     = $applyConfig
    }
}

# =====================================================================
# Low-level operations
# =====================================================================

function Test-NtisRobocopySuccess {
    <# Robocopy: 0-7 success (with notes), 8+ failure. #>
    param([Parameter(Mandatory)] [int] $ExitCode)
    return ($ExitCode -ge 0 -and $ExitCode -lt 8)
}

function Invoke-NtisRobocopy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Source,
        [Parameter(Mandatory)] [string] $Destination,
        [switch] $Mirror,
        [string[]] $ExcludeFiles = @(),
        [string[]] $ExcludeDirs = @()
    )
    if (-not (Test-Path $Source)) { throw "robocopy source not found: $Source" }
    if (-not (Test-Path $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }

    $rcArgs = @($Source, $Destination)
    if ($Mirror) { $rcArgs += '/MIR' } else { $rcArgs += '/E' }
    $rcArgs += @('/R:3', '/W:5', '/XJ', '/NP', '/NFL', '/NDL')
    if ($ExcludeFiles.Count -gt 0) { $rcArgs += '/XF'; $rcArgs += $ExcludeFiles }
    if ($ExcludeDirs.Count -gt 0) { $rcArgs += '/XD'; $rcArgs += $ExcludeDirs }

    & robocopy @rcArgs | Out-Host
    $code = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if (-not (Test-NtisRobocopySuccess $code)) { throw "robocopy $Source -> $Destination failed with exit code $code." }
    return $code
}

function Wait-NtisCondition {
    param([Parameter(Mandatory)] [scriptblock] $Condition, [int] $TimeoutSeconds = 60, [string] $Description = 'condition')
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (& $Condition) { return }
        Start-Sleep -Seconds 2
    }
    throw "Timed out after ${TimeoutSeconds}s waiting for $Description."
}

function Stop-NtisService {
    param([Parameter(Mandatory)] [string] $Name, [int] $TimeoutSeconds = 60)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { throw "Windows service '$Name' does not exist." }
    if ($svc.Status -ne 'Stopped') {
        Write-Host "Stopping service $Name"
        Stop-Service -Name $Name -Force -ErrorAction Stop
    }
    Wait-NtisCondition -TimeoutSeconds $TimeoutSeconds -Description "service $Name to stop" -Condition { (Get-Service -Name $Name).Status -eq 'Stopped' }
}

function Start-NtisService {
    param([Parameter(Mandatory)] [string] $Name, [int] $TimeoutSeconds = 60)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { throw "Windows service '$Name' does not exist." }
    if ($svc.Status -ne 'Running') {
        Write-Host "Starting service $Name"
        Start-Service -Name $Name -ErrorAction Stop
    }
    Wait-NtisCondition -TimeoutSeconds $TimeoutSeconds -Description "service $Name to run" -Condition { (Get-Service -Name $Name).Status -eq 'Running' }
}

function Get-NtisAppPool {
    param([Parameter(Mandatory)] [string] $Site)
    Import-Module WebAdministration -ErrorAction Stop
    $siteObject = Get-Website -Name $Site -ErrorAction SilentlyContinue
    if (-not $siteObject) { throw "IIS website '$Site' does not exist." }
    if (-not $siteObject.applicationPool) { throw "IIS website '$Site' has no application pool." }
    return [string]$siteObject.applicationPool
}

function Stop-NtisApiSite {
    param([Parameter(Mandatory)] [string] $Site, [int] $TimeoutSeconds = 60)
    $pool = Get-NtisAppPool -Site $Site
    Write-Host "Stopping IIS site $Site and app pool $pool"
    if ((Get-Website -Name $Site).State -ne 'Stopped') { Stop-Website -Name $Site -ErrorAction Stop }
    if ((Get-WebAppPoolState -Name $pool).Value -ne 'Stopped') { Stop-WebAppPool -Name $pool -ErrorAction Stop }
    Wait-NtisCondition -TimeoutSeconds $TimeoutSeconds -Description "site $Site / pool $pool to stop" -Condition {
        ((Get-Website -Name $Site).State -eq 'Stopped') -and ((Get-WebAppPoolState -Name $pool).Value -eq 'Stopped')
    }
}

function Start-NtisApiSite {
    param([Parameter(Mandatory)] [string] $Site, [int] $TimeoutSeconds = 60)
    $pool = Get-NtisAppPool -Site $Site
    Write-Host "Starting IIS app pool $pool and site $Site"
    if ((Get-WebAppPoolState -Name $pool).Value -ne 'Started') { Start-WebAppPool -Name $pool -ErrorAction Stop }
    if ((Get-Website -Name $Site).State -ne 'Started') { Start-Website -Name $Site -ErrorAction Stop }
    Wait-NtisCondition -TimeoutSeconds $TimeoutSeconds -Description "site $Site / pool $pool to start" -Condition {
        ((Get-Website -Name $Site).State -eq 'Started') -and ((Get-WebAppPoolState -Name $pool).Value -eq 'Started')
    }
}

function Test-NtisHealth {
    <# GET until 2xx/3xx or attempts run out. #>
    param([Parameter(Mandatory)] [string] $Url, [int] $Attempts = 10, [int] $DelaySeconds = 6, [int] $TimeoutSeconds = 20)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $last = ''
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSeconds -MaximumRedirection 0 -ErrorAction Stop
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 400) { Write-Host "Health OK $Url ($($r.StatusCode))"; return }
            $last = "HTTP $($r.StatusCode)"
        } catch {
            $resp = $null
            if ($_.Exception.PSObject.Properties['Response']) { $resp = $_.Exception.Response }
            if ($resp -and [int]$resp.StatusCode -ge 300 -and [int]$resp.StatusCode -lt 400) { Write-Host "Health OK $Url ($([int]$resp.StatusCode) redirect)"; return }
            $last = $_.Exception.Message
        }
        Write-Host "Health attempt $i/$Attempts for $Url failed: $last"
        if ($i -lt $Attempts) { Start-Sleep -Seconds $DelaySeconds }
    }
    throw "Health check failed for $Url after $Attempts attempts: $last"
}

# =====================================================================
# Backup / restore (F19, F23, F30)
# =====================================================================

function Get-NtisTenantTargets {
    <# The folders a deploy of these components touches: name -> path. #>
    param([Parameter(Mandatory)] $Tenant, [Parameter(Mandatory)] [string[]] $Components)
    $t = [ordered]@{}
    if ($Components -contains 'platform' -or $Components -contains 'dbmanager') {
        $t['api'] = $Tenant.ApiPath
        if ($Tenant.WorkerPath) { $t['worker'] = $Tenant.WorkerPath }
    }
    if ($Components -contains 'ui') { $t['ui'] = $Tenant.UiPath }
    return $t
}

function Backup-NtisTenant {
    param(
        [Parameter(Mandatory)] $Tenant,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Targets,
        [Parameter(Mandatory)] [string] $Root,
        [string[]] $ExcludeDirs = @()
    )
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $backupRoot = Join-Path $Root (Join-Path $Tenant.Tenant (Join-Path $Tenant.Environment $stamp))
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    foreach ($name in @($Targets.Keys)) {
        $src = $Targets[$name]
        if (-not (Test-Path $src)) { Write-Host "Nothing to back up for $name ($src does not exist yet)"; continue }
        Write-Host "Backing up $src -> $backupRoot\$name"
        Invoke-NtisRobocopy -Source $src -Destination (Join-Path $backupRoot $name) -Mirror -ExcludeDirs $ExcludeDirs | Out-Null
    }
    return $backupRoot
}

function Restore-NtisTenant {
    param(
        [Parameter(Mandatory)] [string] $BackupPath,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Targets,
        [string[]] $ExcludeDirs = @()
    )
    foreach ($name in @($Targets.Keys)) {
        $src = Join-Path $BackupPath $name
        if (-not (Test-Path $src)) { continue }
        Write-Host "Restoring $src -> $($Targets[$name])"
        Invoke-NtisRobocopy -Source $src -Destination $Targets[$name] -Mirror -ExcludeDirs $ExcludeDirs | Out-Null
    }
}

function Remove-NtisOldBackups {
    param([Parameter(Mandatory)] [string] $Root, [Parameter(Mandatory)] $Tenant, [int] $Keep = 10)
    $dir = Join-Path $Root (Join-Path $Tenant.Tenant $Tenant.Environment)
    if (-not (Test-Path $dir)) { return }
    $old = @(Get-ChildItem $dir -Directory | Sort-Object Name -Descending | Select-Object -Skip $Keep)
    foreach ($o in $old) {
        Write-Host "Pruning old backup $($o.FullName)"
        Remove-Item $o.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# =====================================================================
# Publish, migrate, configure, stamp
# =====================================================================

function Publish-NtisFolder {
    param(
        [Parameter(Mandatory)] [string] $Source,
        [Parameter(Mandatory)] [string] $Destination,
        [string[]] $PreserveFiles = @(),
        [string[]] $PreserveDirs = @()
    )
    Write-Host "Publishing $Source -> $Destination"
    Invoke-NtisRobocopy -Source $Source -Destination $Destination -Mirror -ExcludeFiles $PreserveFiles -ExcludeDirs $PreserveDirs | Out-Null

    # "Preserve" means never overwrite the server's copy - but a new tenant still needs the packaged default.
    foreach ($pattern in $PreserveFiles) {
        foreach ($f in @(Get-ChildItem -Path $Source -Filter $pattern -File -Force -ErrorAction SilentlyContinue)) {
            $target = Join-Path $Destination $f.Name
            if (-not (Test-Path $target)) {
                Copy-Item -Path $f.FullName -Destination $target
                Write-Host "Seeded missing $($f.Name) from the package"
            }
        }
    }
}

function Copy-NtisConfigFile {
    <# Copies one config file from ntis-configs, expanding #{TOKEN}# secrets. Returns $false when the source is absent. #>
    param([Parameter(Mandatory)] [string] $Source, [Parameter(Mandatory)] [string] $Destination, [hashtable] $Secrets = @{})
    if (-not (Test-Path $Source)) { return $false }
    $text = [System.IO.File]::ReadAllText($Source)
    $expanded = Expand-NtisConfigTokens -Text $text -Secrets $Secrets -Source $Source
    $dir = Split-Path -Parent $Destination
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Destination, $expanded, (New-Object System.Text.UTF8Encoding $false))
    Write-Host "Config applied: $Destination"
    return $true
}

function Set-NtisTenantConfig {
    param(
        [Parameter(Mandatory)] $Tenant,
        [Parameter(Mandatory)] [string[]] $Components,
        [Parameter(Mandatory)] [string] $ConfigRoot,
        [Parameter(Mandatory)] $DeployConfig,
        [hashtable] $Secrets = @{}
    )
    $base = Join-Path $ConfigRoot (Join-Path 'tenants' (Join-Path $Tenant.Tenant $Tenant.Environment))
    $roots = @{ apiPath = $Tenant.ApiPath; uiPath = $Tenant.UiPath; workerPath = $Tenant.WorkerPath }
    foreach ($c in $Components) {
        $def = $DeployConfig.components.PSObject.Properties[$c]
        if (-not $def -or -not $def.Value.PSObject.Properties['configFiles']) { continue }
        foreach ($f in $def.Value.configFiles) {
            $root = $roots[$f.root]
            if (-not $root) { continue }
            $src = Join-Path $base $f.from
            $dst = Join-Path $root $f.to
            if (-not (Copy-NtisConfigFile -Source $src -Destination $dst -Secrets $Secrets)) {
                Write-Host "No $($f.from) in ntis-configs for $($Tenant.Tenant)/$($Tenant.Environment); keeping the server copy of $dst"
            }
        }
    }
}

function Invoke-NtisMigration {
    <# Runs DatabaseManager non-interactively with the tenant's config. Throws on non-zero exit (F20, F28). #>
    param(
        [Parameter(Mandatory)] [string] $PackageDir,
        [Parameter(Mandatory)] $Tenant,
        [Parameter(Mandatory)] [string] $ConfigRoot,
        [Parameter(Mandatory)] $DeployConfig,
        [hashtable] $Secrets = @{}
    )
    $def = $DeployConfig.components.dbmanager
    $exe = Get-ChildItem -Path $PackageDir -Recurse -Filter $def.executable -File | Select-Object -First 1
    if (-not $exe) { throw "$($def.executable) not found in the dbmanager package." }

    $cfgSrc = Join-Path $ConfigRoot (Join-Path 'tenants' (Join-Path $Tenant.Tenant (Join-Path $Tenant.Environment $def.configFrom)))
    if (-not (Copy-NtisConfigFile -Source $cfgSrc -Destination (Join-Path $exe.DirectoryName 'appsettings.json') -Secrets $Secrets)) {
        throw "Database config missing: $cfgSrc. Add it to ntis-configs or set 'migrateDatabase': false for this tenant."
    }

    Write-Host "Running $($exe.Name) $($def.arguments -join ' ') for $($Tenant.Tenant)/$($Tenant.Environment)"
    Push-Location $exe.DirectoryName
    try {
        & $exe.FullName @($def.arguments) | Out-Host
        $code = $LASTEXITCODE
    } finally { Pop-Location }
    if ($code -ne 0) { throw "Database migration failed with exit code $code." }
}

function Write-NtisVersionStamp {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [hashtable] $Data)
    if (-not (Test-Path $Path)) { return }
    $json = ([pscustomobject]$Data) | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText((Join-Path $Path 'version.json'), $json, (New-Object System.Text.UTF8Encoding $false))
}

function Expand-NtisPackage {
    param([Parameter(Mandatory)] [string] $Zip, [Parameter(Mandatory)] [string] $Destination)
    if (Test-Path $Destination) { Remove-Item $Destination -Recurse -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Zip, $Destination)
    return $Destination
}

# =====================================================================
# The transaction (design sec. 2.9)
# =====================================================================

function Invoke-NtisTenantDeploy {
    <#
      -Packages   hashtable component -> extracted package folder (only for components being deployed)
      -Stamp      hashtable written to version.json (version, env, run url, per-component sha/tree)
      Throws on failure after restoring the backup and restarting services.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Tenant,
        [Parameter(Mandatory)] [string] $TenantEnvironment,
        [Parameter(Mandatory)] [string[]] $Components,
        [Parameter(Mandatory)] [hashtable] $Packages,
        [Parameter(Mandatory)] [string] $ConfigRoot,
        [Parameter(Mandatory)] $DeployConfig,
        [hashtable] $Secrets = @{},
        [hashtable] $Stamp = @{},
        [string] $BackupRoot,
        [switch] $SkipHealthCheck
    )

    # ---- preflight --------------------------------------------------
    if ($Tenant.Environment -ne $TenantEnvironment) {
        throw "Tenant $($Tenant.Url) is a '$($Tenant.Environment)' tenant; refusing to deploy '$TenantEnvironment' packages to it."
    }
    foreach ($c in $Components) {
        if (-not $Packages.ContainsKey($c)) { throw "No package supplied for component '$c'." }
    }
    if (-not $BackupRoot) { $BackupRoot = $DeployConfig.backup.root }
    $timeout = [int]$DeployConfig.serviceTimeoutSeconds

    $needApi = ($Components -contains 'platform') -or ($Components -contains 'dbmanager')
    $needUi = $Components -contains 'ui'
    $needWorker = $needApi -and [bool]$Tenant.WorkerService
    $migrate = ($Components -contains 'dbmanager') -and $Tenant.MigrateDatabase

    $targets = Get-NtisTenantTargets -Tenant $Tenant -Components $Components
    $excludeBackup = @($DeployConfig.backup.excludeDirs)

    # ---- backup (fails the deploy before anything is stopped) --------
    $backup = Backup-NtisTenant -Tenant $Tenant -Targets $targets -Root $BackupRoot -ExcludeDirs $excludeBackup
    Write-Host "Backup: $backup"

    $stopped = New-Object System.Collections.Generic.List[string]
    try {
        # ---- stop -----------------------------------------------------
        if ($needUi) { Stop-NtisService -Name $Tenant.UiService -TimeoutSeconds $timeout; $stopped.Add('ui') }
        if ($needWorker) { Stop-NtisService -Name $Tenant.WorkerService -TimeoutSeconds $timeout; $stopped.Add('worker') }
        if ($needApi) { Stop-NtisApiSite -Site $Tenant.ApiSite -TimeoutSeconds $timeout; $stopped.Add('api') }

        # ---- migrate (db -> platform -> ui order) ----------------------
        if ($migrate) {
            Invoke-NtisMigration -PackageDir $Packages['dbmanager'] -Tenant $Tenant -ConfigRoot $ConfigRoot -DeployConfig $DeployConfig -Secrets $Secrets
        } elseif ($Components -contains 'dbmanager') {
            Write-Host "Tenant $($Tenant.Url) has migrateDatabase=false; skipping migration."
        }

        # ---- publish ---------------------------------------------------
        $extraPreserve = @($Tenant.PreserveFiles)
        if ($Components -contains 'platform') {
            $p = $DeployConfig.components.platform
            $apiSrc = Join-Path $Packages['platform'] $p.packageFolders.api
            Publish-NtisFolder -Source $apiSrc -Destination $Tenant.ApiPath -PreserveFiles (@($p.preserveFiles) + $extraPreserve) -PreserveDirs @($p.preserveDirs)
            $workerSrc = Join-Path $Packages['platform'] $p.packageFolders.worker
            if ($Tenant.WorkerPath -and (Test-Path $workerSrc)) {
                Publish-NtisFolder -Source $workerSrc -Destination $Tenant.WorkerPath -PreserveFiles (@($p.preserveFiles) + $extraPreserve) -PreserveDirs @($p.preserveDirs)
            }
        }
        if ($needUi) {
            $u = $DeployConfig.components.ui
            Publish-NtisFolder -Source $Packages['ui'] -Destination $Tenant.UiPath -PreserveFiles (@($u.preserveFiles) + $extraPreserve) -PreserveDirs @($u.preserveDirs)
        }

        # ---- config + stamp --------------------------------------------
        if ($Tenant.ApplyConfig) {
            Set-NtisTenantConfig -Tenant $Tenant -Components $Components -ConfigRoot $ConfigRoot -DeployConfig $DeployConfig -Secrets $Secrets
        } else {
            Write-Host "Tenant $($Tenant.Url) has applyConfig=false; server config files are left as they are."
        }
        foreach ($name in @($targets.Keys)) { Write-NtisVersionStamp -Path $targets[$name] -Data $Stamp }

        # ---- start (reverse order) --------------------------------------
        if ($stopped.Contains('api')) { Start-NtisApiSite -Site $Tenant.ApiSite -TimeoutSeconds $timeout }
        if ($stopped.Contains('worker')) { Start-NtisService -Name $Tenant.WorkerService -TimeoutSeconds $timeout }
        if ($stopped.Contains('ui')) { Start-NtisService -Name $Tenant.UiService -TimeoutSeconds $timeout }

        # ---- health -----------------------------------------------------
        if (-not $SkipHealthCheck) {
            $h = $DeployConfig.health
            if ($needApi -and $Tenant.ApiHealthUrl) { Test-NtisHealth -Url $Tenant.ApiHealthUrl -Attempts $h.attempts -DelaySeconds $h.delaySeconds -TimeoutSeconds $h.timeoutSeconds }
            elseif ($needApi) { Write-Warning "Tenant $($Tenant.Url) has no apiHealthUrl; API health not checked." }
            if ($Tenant.UiHealthUrl) { Test-NtisHealth -Url $Tenant.UiHealthUrl -Attempts $h.attempts -DelaySeconds $h.delaySeconds -TimeoutSeconds $h.timeoutSeconds }
        }
    } catch {
        $failure = $_
        Write-Host "::error::Deploy of $($Tenant.Url) failed: $($failure.Exception.Message). Rolling back from $backup"
        $rollbackErrors = @()
        try { if ($needUi) { Stop-NtisService -Name $Tenant.UiService -TimeoutSeconds $timeout } } catch { $rollbackErrors += $_.Exception.Message }
        try { if ($needWorker) { Stop-NtisService -Name $Tenant.WorkerService -TimeoutSeconds $timeout } } catch { $rollbackErrors += $_.Exception.Message }
        try { if ($needApi) { Stop-NtisApiSite -Site $Tenant.ApiSite -TimeoutSeconds $timeout } } catch { $rollbackErrors += $_.Exception.Message }
        try { Restore-NtisTenant -BackupPath $backup -Targets $targets -ExcludeDirs $excludeBackup } catch { $rollbackErrors += "restore: $($_.Exception.Message)" }
        try { if ($needApi) { Start-NtisApiSite -Site $Tenant.ApiSite -TimeoutSeconds $timeout } } catch { $rollbackErrors += $_.Exception.Message }
        try { if ($needWorker) { Start-NtisService -Name $Tenant.WorkerService -TimeoutSeconds $timeout } } catch { $rollbackErrors += $_.Exception.Message }
        try { if ($needUi) { Start-NtisService -Name $Tenant.UiService -TimeoutSeconds $timeout } } catch { $rollbackErrors += $_.Exception.Message }

        $msg = "Deploy of $($Tenant.Url) failed and was rolled back: $($failure.Exception.Message)"
        if ($migrate) { $msg += ' NOTE: database migrations are not rolled back.' }
        if ($rollbackErrors.Count -gt 0) { $msg += " ROLLBACK PROBLEMS: $($rollbackErrors -join ' | ') - manual action required, backup at $backup" }
        throw $msg
    }

    Remove-NtisOldBackups -Root $BackupRoot -Tenant $Tenant -Keep ([int]$DeployConfig.backup.keep)
    return $backup
}

Export-ModuleMember -Function *-Ntis*
