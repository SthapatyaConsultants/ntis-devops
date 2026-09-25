#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\scripts\NtisDeploy.psm1') -Force -DisableNameChecking
    $script:DeployConfig = Get-NtisDeployConfig

    $script:TenantsFile = Join-Path $TestDrive 'tenants.json'
    @'
{
  "ptisthane.scipl.info.in": {
    "environment": "prod", "tenant": "ptisthane",
    "apiSite": "ptisthane-api", "apiPath": "E:\\WebApp\\ptisthane-api",
    "uiPath": "E:\\WebApp\\ptisthane", "uiService": "ptisthane-ui",
    "apiHealthUrl": "https://ptisthaneapi.scipl.info.in/health",
    "applyConfig": true
  },
  "ptisthane-qa.scipl.info.in": {
    "environment": "qa", "tenant": "ptisthane",
    "apiSite": "ptisthane-api-qa", "apiPath": "E:\\WebApp\\ptisthane-api-qa",
    "uiPath": "E:\\WebApp\\ptisthane-qa", "uiService": "ptisthane-ui-qa",
    "migrateDatabase": false
  },
  "broken.scipl.info.in": { "environment": "qa", "tenant": "broken" }
}
'@ | Set-Content -Path $script:TenantsFile -Encoding UTF8
}

Describe 'Get-NtisTenant' {
    It 'loads a tenant case-insensitively with defaults' {
        $t = Get-NtisTenant -TenantsFile $TenantsFile -Url 'PTISTHANE.scipl.info.in'
        $t.Environment | Should -Be 'prod'
        $t.UiHealthUrl | Should -Be 'https://ptisthane.scipl.info.in/'
        $t.MigrateDatabase | Should -BeTrue
        $t.WorkerService | Should -Be ''
    }
    It 'honours migrateDatabase=false' {
        (Get-NtisTenant -TenantsFile $TenantsFile -Url 'ptisthane-qa.scipl.info.in').MigrateDatabase | Should -BeFalse
    }
    It 'rejects unknown URLs' {
        { Get-NtisTenant -TenantsFile $TenantsFile -Url 'nope.scipl.info.in' } | Should -Throw '*No tenant*'
    }
    It 'rejects incomplete tenants' {
        { Get-NtisTenant -TenantsFile $TenantsFile -Url 'broken.scipl.info.in' } | Should -Throw '*missing*'
    }
    It 'rejects injection attempts in the URL' {
        { Get-NtisTenant -TenantsFile $TenantsFile -Url 'x.in"; Remove-Item C:\ -Recurse' } | Should -Throw '*Invalid tenant URL*'
    }
}

Describe 'Test-NtisRobocopySuccess' {
    It 'treats <code> as <ok>' -TestCases @(
        @{ code = 0; ok = $true }, @{ code = 1; ok = $true }, @{ code = 3; ok = $true },
        @{ code = 7; ok = $true }, @{ code = 8; ok = $false }, @{ code = 16; ok = $false }
    ) {
        Test-NtisRobocopySuccess $code | Should -Be $ok
    }
}

Describe 'Invoke-NtisTenantDeploy' {
    BeforeEach {
        $script:calls = New-Object System.Collections.Generic.List[string]
        Mock -ModuleName NtisDeploy Backup-NtisTenant { $calls.Add('backup'); 'C:\Backup\t\prod\1' }
        Mock -ModuleName NtisDeploy Restore-NtisTenant { $calls.Add('restore') }
        Mock -ModuleName NtisDeploy Remove-NtisOldBackups { }
        Mock -ModuleName NtisDeploy Stop-NtisService { $calls.Add("stop-svc:$Name") }
        Mock -ModuleName NtisDeploy Start-NtisService { $calls.Add("start-svc:$Name") }
        Mock -ModuleName NtisDeploy Stop-NtisApiSite { $calls.Add("stop-site:$Site") }
        Mock -ModuleName NtisDeploy Start-NtisApiSite { $calls.Add("start-site:$Site") }
        Mock -ModuleName NtisDeploy Invoke-NtisMigration { $calls.Add('migrate') }
        Mock -ModuleName NtisDeploy Publish-NtisFolder { $calls.Add("publish:$Destination") }
        Mock -ModuleName NtisDeploy Set-NtisTenantConfig { $calls.Add('config') }
        Mock -ModuleName NtisDeploy Write-NtisVersionStamp { }
        Mock -ModuleName NtisDeploy Test-NtisHealth { $calls.Add("health:$Url") }
        $script:tenant = Get-NtisTenant -TenantsFile $TenantsFile -Url 'ptisthane.scipl.info.in'
        $script:pkgs = @{ dbmanager = 'C:\p\db'; platform = 'C:\p\platform'; ui = 'C:\p\ui' }
    }

    It 'runs backup -> stop -> migrate -> publish -> config -> start -> health in order' {
        Invoke-NtisTenantDeploy -Tenant $tenant -TenantEnvironment prod -Components @('dbmanager', 'platform', 'ui') -Packages $pkgs -ConfigRoot 'C:\cfg' -DeployConfig $DeployConfig | Out-Null
        $calls | Should -Be @(
            'backup',
            'stop-svc:ptisthane-ui', 'stop-site:ptisthane-api',
            'migrate',
            'publish:E:\WebApp\ptisthane-api', 'publish:E:\WebApp\ptisthane',
            'config',
            'start-site:ptisthane-api', 'start-svc:ptisthane-ui',
            'health:https://ptisthaneapi.scipl.info.in/health', 'health:https://ptisthane.scipl.info.in/'
        )
    }

    It 'only touches the UI for a UI-only deploy' {
        Invoke-NtisTenantDeploy -Tenant $tenant -TenantEnvironment prod -Components @('ui') -Packages $pkgs -ConfigRoot 'C:\cfg' -DeployConfig $DeployConfig -SkipHealthCheck | Out-Null
        $calls | Should -Not -Contain 'stop-site:ptisthane-api'
        $calls | Should -Not -Contain 'migrate'
        $calls | Should -Contain 'stop-svc:ptisthane-ui'
    }

    It 'refuses to deploy packages of another environment' {
        { Invoke-NtisTenantDeploy -Tenant $tenant -TenantEnvironment qa -Components @('ui') -Packages $pkgs -ConfigRoot 'C:\cfg' -DeployConfig $DeployConfig } | Should -Throw "*refusing*"
        $calls | Should -Not -Contain 'backup'
    }

    It 'does not stop anything when the backup fails' {
        Mock -ModuleName NtisDeploy Backup-NtisTenant { throw 'disk full' }
        { Invoke-NtisTenantDeploy -Tenant $tenant -TenantEnvironment prod -Components @('ui') -Packages $pkgs -ConfigRoot 'C:\cfg' -DeployConfig $DeployConfig } | Should -Throw '*disk full*'
        $calls | Should -Not -Contain 'stop-svc:ptisthane-ui'
    }

    It 'restores and restarts when the health check fails' {
        Mock -ModuleName NtisDeploy Test-NtisHealth { throw 'HTTP 502' }
        { Invoke-NtisTenantDeploy -Tenant $tenant -TenantEnvironment prod -Components @('platform', 'ui') -Packages $pkgs -ConfigRoot 'C:\cfg' -DeployConfig $DeployConfig } | Should -Throw '*rolled back*HTTP 502*'
        $calls | Should -Contain 'restore'
        $afterRestore = $calls.GetRange($calls.IndexOf('restore'), $calls.Count - $calls.IndexOf('restore'))
        $afterRestore | Should -Contain 'start-site:ptisthane-api'
        $afterRestore | Should -Contain 'start-svc:ptisthane-ui'
    }

    It 'warns that migrations are not rolled back' {
        Mock -ModuleName NtisDeploy Publish-NtisFolder { throw 'robocopy 16' }
        { Invoke-NtisTenantDeploy -Tenant $tenant -TenantEnvironment prod -Components @('dbmanager', 'platform') -Packages $pkgs -ConfigRoot 'C:\cfg' -DeployConfig $DeployConfig } | Should -Throw '*migrations are not rolled back*'
    }

    It 'leaves server config alone unless the tenant opts in' {
        $qa = Get-NtisTenant -TenantsFile $TenantsFile -Url 'ptisthane-qa.scipl.info.in'
        $qa.ApplyConfig | Should -BeFalse
        Invoke-NtisTenantDeploy -Tenant $qa -TenantEnvironment qa -Components @('ui') -Packages $pkgs -ConfigRoot 'C:\cfg' -DeployConfig $DeployConfig -SkipHealthCheck | Out-Null
        $calls | Should -Not -Contain 'config'
    }

    It 'skips migration for tenants with migrateDatabase=false' {
        $qa = Get-NtisTenant -TenantsFile $TenantsFile -Url 'ptisthane-qa.scipl.info.in'
        Invoke-NtisTenantDeploy -Tenant $qa -TenantEnvironment qa -Components @('dbmanager') -Packages $pkgs -ConfigRoot 'C:\cfg' -DeployConfig $DeployConfig -SkipHealthCheck | Out-Null
        $calls | Should -Not -Contain 'migrate'
    }
}

Describe 'Copy-NtisConfigFile' {
    It 'expands secrets and reports missing sources' {
        $src = Join-Path $TestDrive 'a.json'
        Set-Content $src '{"cs":"Password=#{DB_PASSWORD}#"}' -Encoding UTF8
        $dst = Join-Path $TestDrive 'out\a.json'
        Copy-NtisConfigFile -Source $src -Destination $dst -Secrets @{ DB_PASSWORD = 's3cret' } | Should -BeTrue
        Get-Content $dst -Raw | Should -Match 's3cret'
        Copy-NtisConfigFile -Source (Join-Path $TestDrive 'missing.json') -Destination $dst | Should -BeFalse
    }
}

Describe 'Publish-NtisFolder (real robocopy)' {
    It 'mirrors the package, keeps preserved files and seeds missing ones' {
        $pkg = Join-Path $TestDrive 'pkg'; $site = Join-Path $TestDrive 'uisite'
        New-Item -ItemType Directory "$pkg\.next", $site, "$site\Logs" -Force | Out-Null
        Set-Content "$pkg\.next\app.js" 'new'
        Set-Content "$pkg\server.js" 'packaged'
        Set-Content "$pkg\.env" 'packaged-env'
        Set-Content "$site\.env" 'server-env'
        Set-Content "$site\stale.js" 'old'
        Set-Content "$site\Logs\today.log" 'log'

        Publish-NtisFolder -Source $pkg -Destination $site -PreserveFiles @('.env', 'server.js') -PreserveDirs @('Logs')

        Get-Content "$site\.next\app.js" | Should -Be 'new'
        Get-Content "$site\.env" | Should -Be 'server-env'
        Get-Content "$site\server.js" | Should -Be 'packaged'
        Test-Path "$site\stale.js" | Should -BeFalse
        Test-Path "$site\Logs\today.log" | Should -BeTrue

        Set-Content "$pkg\server.js" 'packaged-v2'
        Publish-NtisFolder -Source $pkg -Destination $site -PreserveFiles @('.env', 'server.js') -PreserveDirs @('Logs')
        Get-Content "$site\server.js" | Should -Be 'packaged'
    }
}

Describe 'Backup and restore (real robocopy)' {
    It 'backs up, prunes and restores a folder' {
        $site = Join-Path $TestDrive 'site'
        New-Item -ItemType Directory "$site\bin" -Force | Out-Null
        Set-Content "$site\bin\app.dll" 'v1'
        New-Item -ItemType Directory "$site\Uploads" -Force | Out-Null
        Set-Content "$site\Uploads\user.pdf" 'data'
        $t = [pscustomobject]@{ Tenant = 'demo'; Environment = 'qa' }
        $targets = [ordered]@{ api = $site }
        $root = Join-Path $TestDrive 'backup'

        $b = Backup-NtisTenant -Tenant $t -Targets $targets -Root $root -ExcludeDirs @('Uploads')
        Test-Path "$b\api\bin\app.dll" | Should -BeTrue
        Test-Path "$b\api\Uploads" | Should -BeFalse

        Set-Content "$site\bin\app.dll" 'v2'
        Set-Content "$site\bin\new.dll" 'x'
        Restore-NtisTenant -BackupPath $b -Targets $targets -ExcludeDirs @('Uploads')
        Get-Content "$site\bin\app.dll" | Should -Be 'v1'
        Test-Path "$site\bin\new.dll" | Should -BeFalse
        Test-Path "$site\Uploads\user.pdf" | Should -BeTrue

        1..3 | ForEach-Object { New-Item -ItemType Directory (Join-Path $root "demo\qa\2020010$_-000000") -Force | Out-Null }
        Remove-NtisOldBackups -Root $root -Tenant $t -Keep 2
        @(Get-ChildItem (Join-Path $root 'demo\qa') -Directory).Count | Should -Be 2
    }
}
