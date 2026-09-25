#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\scripts\NtisPipeline.psm1') -Force -DisableNameChecking
    $script:Config = Get-NtisPipelineConfig
    $script:Policy = Get-NtisPrPolicy
}

Describe 'Resolve-NtisEnvironmentKey' {
    It 'maps <ref> to <expected>' -TestCases @(
        @{ ref = 'develop'; expected = 'dev' }
        @{ ref = 'refs/heads/qa'; expected = 'qa' }
        @{ ref = 'staging'; expected = 'staging' }
        @{ ref = 'release/2.4.0'; expected = 'staging' }
        @{ ref = 'main'; expected = 'production' }
    ) {
        Resolve-NtisEnvironmentKey -Ref $ref -Config $Config | Should -Be $expected
    }
    It 'does not deploy <ref>' -TestCases @(
        @{ ref = 'feature/PROJ-1-x' }, @{ ref = 'hotfix/PROJ-2-y' }, @{ ref = 'dev' }, @{ ref = 'master' }
    ) {
        Resolve-NtisEnvironmentKey -Ref $ref -Config $Config | Should -BeNullOrEmpty
    }
}

Describe 'Select-NtisSourceRef' {
    It 'uses the single release branch for staging' {
        $staging = Get-NtisEnvironment -Key staging -Config $Config
        Select-NtisSourceRef -EnvironmentDefinition $staging -ReleaseBranches @('release/2.4.0') | Should -Be 'release/2.4.0'
    }
    It 'falls back to the staging branch without a release' {
        $staging = Get-NtisEnvironment -Key staging -Config $Config
        Select-NtisSourceRef -EnvironmentDefinition $staging -ReleaseBranches @() | Should -Be 'staging'
    }
    It 'refuses two release branches' {
        $staging = Get-NtisEnvironment -Key staging -Config $Config
        { Select-NtisSourceRef -EnvironmentDefinition $staging -ReleaseBranches @('release/2.4.0', 'release/2.5.0') } | Should -Throw '*one active release*'
    }
    It 'ignores release branches for other environments' {
        $qa = Get-NtisEnvironment -Key qa -Config $Config
        Select-NtisSourceRef -EnvironmentDefinition $qa -ReleaseBranches @('release/2.4.0') | Should -Be 'qa'
    }
}

Describe 'Get-NtisTenantsForEnvironment' {
    It 'filters and sorts tenant URLs' {
        $tenants = '{ "b-qa.x.in": {"environment":"qa"}, "a-qa.x.in": {"environment":"qa"}, "a.x.in": {"environment":"prod"} }' | ConvertFrom-Json
        Get-NtisTenantsForEnvironment -Tenants $tenants -TenantEnvironment qa | Should -Be @('a-qa.x.in', 'b-qa.x.in')
        Get-NtisTenantsForEnvironment -Tenants $tenants -TenantEnvironment prod | Should -Be @('a.x.in')
    }
}

Describe 'Semver helpers' {
    It 'parses strict X.Y.Z only' {
        (ConvertTo-NtisSemVer 'v2.4.1').ToString() | Should -Be '2.4.1'
        ConvertTo-NtisSemVer '1.2.3.4' | Should -BeNullOrEmpty
        ConvertTo-NtisSemVer 'v2.4' | Should -BeNullOrEmpty
    }
    It 'extracts the version from a PR title' {
        Get-NtisVersionFromTitle 'REL-12: release v2.4.0 (staging -> main)' | Should -Be '2.4.0'
        Get-NtisVersionFromTitle 'PROJ-1: bump lib to v2.4.0.1' | Should -BeNullOrEmpty
        Get-NtisVersionFromTitle 'PROJ-1: no version' | Should -BeNullOrEmpty
    }
    It 'finds the latest semver tag and ignores others' {
        (Get-NtisLatestSemVer @('v1.9.0', 'v1.10.0', 'build-5', 'v1.10.0-rc1')).ToString() | Should -Be '1.10.0'
        Get-NtisLatestSemVer @() | Should -BeNullOrEmpty
    }
}

Describe 'Test-NtisPrPolicy' {
    It 'accepts a feature PR into develop' {
        $r = Test-NtisPrPolicy -Base develop -Head 'feature/PROJ-214-login-otp' -Title 'PROJ-214: Add OTP login' -Policy $Policy
        $r.Passed | Should -BeTrue
    }
    It 'rejects a feature PR without a ticket in the title' {
        $r = Test-NtisPrPolicy -Base develop -Head 'feature/PROJ-214-login-otp' -Title 'Add OTP login' -Policy $Policy
        $r.Passed | Should -BeFalse
        ($r.Errors -join ' ') | Should -Match 'ticket'
    }
    It 'rejects a badly named branch' {
        $r = Test-NtisPrPolicy -Base develop -Head 'feat/login' -Title 'PROJ-1: x' -Policy $Policy
        $r.Passed | Should -BeFalse
    }
    It 'rejects skipping a stage (develop -> staging)' {
        $r = Test-NtisPrPolicy -Base staging -Head develop -Title 'REL-1: promote' -Policy $Policy
        $r.Passed | Should -BeFalse
    }
    It 'rejects a feature branch straight into qa' {
        $r = Test-NtisPrPolicy -Base qa -Head 'feature/PROJ-1-x' -Title 'PROJ-1: x' -Policy $Policy
        $r.Passed | Should -BeFalse
    }
    It 'accepts develop -> qa' {
        (Test-NtisPrPolicy -Base qa -Head develop -Title 'REL-7: promote develop to qa' -Policy $Policy).Passed | Should -BeTrue
    }
    It 'exempts back-merge PRs from the ticket rule' {
        (Test-NtisPrPolicy -Base develop -Head 'backmerge/v2.4.1-develop' -Title 'Back-merge v2.4.1 into develop' -Policy $Policy).Passed | Should -BeTrue
    }
    It 'blocks qa -> staging while a back-merge into qa is open' {
        $r = Test-NtisPrPolicy -Base staging -Head qa -Title 'REL-7: promote' -Policy $Policy -Facts @{ OpenBackmerges = @{ qa = 1 } }
        $r.Passed | Should -BeFalse
        ($r.Errors -join ' ') | Should -Match 'back-merge'
    }
    It 'requires a version on PRs into main' {
        $r = Test-NtisPrPolicy -Base main -Head staging -Title 'REL-7: release' -Policy $Policy -Facts @{ LatestVersion = [version]'2.4.0' }
        $r.Passed | Should -BeFalse
    }
    It 'requires the version to increase' {
        $r = Test-NtisPrPolicy -Base main -Head staging -Title 'REL-7: release v2.4.0' -Policy $Policy -Facts @{ LatestVersion = [version]'2.4.0' }
        $r.Passed | Should -BeFalse
    }
    It 'accepts a new minor from staging' {
        (Test-NtisPrPolicy -Base main -Head staging -Title 'REL-7: release v2.5.0' -Policy $Policy -Facts @{ LatestVersion = [version]'2.4.0' }).Passed | Should -BeTrue
    }
    It 'accepts the first release when no tag exists' {
        (Test-NtisPrPolicy -Base main -Head staging -Title 'REL-1: release v1.0.0' -Policy $Policy -Facts @{ LatestVersion = $null }).Passed | Should -BeTrue
    }
    It 'requires a hotfix to be a PATCH bump' {
        (Test-NtisPrPolicy -Base main -Head 'hotfix/PROJ-301-payment-crash' -Title 'PROJ-301: fix v2.5.0' -Policy $Policy -Facts @{ LatestVersion = [version]'2.4.0' }).Passed | Should -BeFalse
        (Test-NtisPrPolicy -Base main -Head 'hotfix/PROJ-301-payment-crash' -Title 'PROJ-301: fix v2.4.1' -Policy $Policy -Facts @{ LatestVersion = [version]'2.4.0' }).Passed | Should -BeTrue
    }
    It 'requires release/* titles to match the branch version' {
        (Test-NtisPrPolicy -Base main -Head 'release/2.5.0' -Title 'REL-9: release v2.6.0' -Policy $Policy -Facts @{ LatestVersion = [version]'2.4.0' }).Passed | Should -BeFalse
        (Test-NtisPrPolicy -Base main -Head 'release/2.5.0' -Title 'REL-9: release v2.5.0' -Policy $Policy -Facts @{ LatestVersion = [version]'2.4.0' }).Passed | Should -BeTrue
    }
    It 'allows only bugfix branches into release/*' {
        (Test-NtisPrPolicy -Base 'release/2.5.0' -Head 'bugfix/PROJ-230-cart-total' -Title 'PROJ-230: cart total' -Policy $Policy -Facts @{ ReleaseBranches = @('release/2.5.0') }).Passed | Should -BeTrue
        (Test-NtisPrPolicy -Base 'release/2.5.0' -Head 'feature/PROJ-231-new' -Title 'PROJ-231: new' -Policy $Policy -Facts @{ ReleaseBranches = @('release/2.5.0') }).Passed | Should -BeFalse
    }
    It 'blocks PRs into a release branch while two releases exist' {
        (Test-NtisPrPolicy -Base 'release/2.5.0' -Head 'bugfix/PROJ-230-x' -Title 'PROJ-230: x' -Policy $Policy -Facts @{ ReleaseBranches = @('release/2.5.0', 'release/2.6.0') }).Passed | Should -BeFalse
    }
    It 'does not govern other bases' {
        $r = Test-NtisPrPolicy -Base 'feature/PROJ-1-x' -Head 'feature/PROJ-2-y' -Title 'x' -Policy $Policy
        $r.Governed | Should -BeFalse
        $r.Passed | Should -BeTrue
    }
}

Describe 'Test-NtisPromotionGate' {
    BeforeAll {
        function New-C($name, $tree, $pr = '', $src = '') { @{ Name = $name; Tree = $tree; PrHead = $pr; SourceRef = $src } }
    }
    It 'passes anything in dev' {
        (Test-NtisPromotionGate -EnvironmentKey dev -Components @(New-C ui t1)).Passed | Should -BeTrue
    }
    It 'passes new trees in qa but notes them' {
        $r = Test-NtisPromotionGate -EnvironmentKey qa -Components @(New-C ui t9) -LowerTrees @{ ui = @('t1') }
        $r.Passed | Should -BeTrue
        $r.Reason | Should -Match 'new tree'
    }
    It 'passes staging only for trees QA has run' {
        (Test-NtisPromotionGate -EnvironmentKey staging -Components @(New-C ui t1) -LowerTrees @{ ui = @('t1') }).Passed | Should -BeTrue
        (Test-NtisPromotionGate -EnvironmentKey staging -Components @(New-C ui t2) -LowerTrees @{ ui = @('t1') }).Passed | Should -BeFalse
    }
    It 'passes staging for release branches and back-merges' {
        (Test-NtisPromotionGate -EnvironmentKey staging -Components @(New-C ui t2 '' 'release/2.5.0')).Passed | Should -BeTrue
        (Test-NtisPromotionGate -EnvironmentKey staging -Components @(New-C ui t2 'backmerge/v2.4.1-staging' 'staging')).Passed | Should -BeTrue
    }
    It 'passes production only when identical to staging' {
        (Test-NtisPromotionGate -EnvironmentKey production -Components @(New-C platform p1) -LowerCurrent @{ platform = 'p1' }).Passed | Should -BeTrue
        (Test-NtisPromotionGate -EnvironmentKey production -Components @(New-C platform p2) -LowerCurrent @{ platform = 'p1' }).Passed | Should -BeFalse
    }
    It 'passes a hotfix to production' {
        (Test-NtisPromotionGate -EnvironmentKey production -Components @(New-C platform p2 'hotfix/PROJ-301-x') -LowerCurrent @{ platform = 'p1' }).Passed | Should -BeTrue
    }
    It 'passes an unchanged component everywhere' {
        (Test-NtisPromotionGate -EnvironmentKey production -Components @(New-C ui u1) -Current @{ ui = 'u1' } -LowerCurrent @{ ui = 'u0' }).Passed | Should -BeTrue
    }
    It 'evaluates each component separately' {
        $r = Test-NtisPromotionGate -EnvironmentKey production -Components @((New-C ui u1), (New-C platform p2)) -LowerCurrent @{ ui = 'u1'; platform = 'p1' }
        ($r | Where-Object Name -EQ 'ui').Passed | Should -BeTrue
        ($r | Where-Object Name -EQ 'platform').Passed | Should -BeFalse
    }
}

Describe 'Get-NtisChangedComponents' {
    It 'returns changed components in db -> platform -> ui order' {
        $c = @(@{ Name = 'ui'; Tree = 'u2' }, @{ Name = 'dbmanager'; Tree = 'd2' }, @{ Name = 'platform'; Tree = 'p1' })
        $r = Get-NtisChangedComponents -Components $c -Current @{ ui = 'u1'; dbmanager = 'd1'; platform = 'p1' } -Config $Config
        @($r | ForEach-Object { $_.Name }) | Should -Be @('dbmanager', 'ui')
    }
    It 'treats a first deploy as all changed' {
        $c = @(@{ Name = 'ui'; Tree = 'u' }, @{ Name = 'platform'; Tree = 'p' })
        @(Get-NtisChangedComponents -Components $c -Current @{} -Config $Config).Count | Should -Be 2
    }
}

Describe 'State helpers' {
    It 'overlays deployed components on the previous state' {
        $prev = '{ "components": { "ui": { "tree": "u1" }, "platform": { "tree": "p1" } } }' | ConvertFrom-Json
        $s = New-NtisEnvironmentState -EnvironmentKey qa -Previous $prev -Deployed @([pscustomobject]@{ Name = 'ui'; Repo = 'o/ntis-ui'; SourceRef = 'qa'; Sha = 's2'; Tree = 'u2' })
        $s.components['ui'].tree | Should -Be 'u2'
        $s.components['platform'].tree | Should -Be 'p1'
        $trees = Get-NtisCurrentTrees (($s | ConvertTo-Json -Depth 10) | ConvertFrom-Json)
        $trees['ui'] | Should -Be 'u2'
    }
    It 'accumulates distinct trees in the index' {
        $idx = '{ "ui": ["u1"] }' | ConvertFrom-Json
        $h = Merge-NtisTreeIndex -Index $idx -Components @(@{ Name = 'ui'; Tree = 'u2' }, @{ Name = 'ui'; Tree = 'u1' }, @{ Name = 'platform'; Tree = 'p1' })
        @($h['ui']) | Should -Be @('u1', 'u2')
        @($h['platform']) | Should -Be @('p1')
    }
}

Describe 'Expand-NtisConfigTokens' {
    It 'replaces tokens' {
        Expand-NtisConfigTokens -Text 'Password=#{DB_PASSWORD}#;User=#{DB_USER}#' -Secrets @{ DB_PASSWORD = 'p@ss'; DB_USER = 'u' } | Should -Be 'Password=p@ss;User=u'
    }
    It 'leaves text without tokens alone' {
        Expand-NtisConfigTokens -Text '{ "a": 1 }' | Should -Be '{ "a": 1 }'
    }
    It 'throws on missing secrets and names them' {
        { Expand-NtisConfigTokens -Text '#{A}# #{B}#' -Secrets @{ A = 'x' } } | Should -Throw '*B*'
    }
}
