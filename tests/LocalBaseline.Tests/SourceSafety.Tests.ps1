BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\tools\LocalBaseline.psm1') -Force
}

Describe 'Source-only baseline boundary' {
    BeforeEach {
        $repository = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($repository) | Out-Null
        & git init --quiet $repository
        if ($LASTEXITCODE -ne 0) { throw 'Local test repository initialization failed.' }
        [IO.File]::WriteAllText((Join-Path $repository '.gitignore'), "**/bin/`n**/obj/`n/.test-work/`n/.bootstrap/`n")
        [IO.File]::WriteAllText((Join-Path $repository 'tracked.cs'), 'class Tracked {}')
        & git -C $repository add -- .gitignore tracked.cs
        if ($LASTEXITCODE -ne 0) { throw 'Local test source indexing failed.' }
    }

    It 'includes untracked authored source but excludes generated and operational files' {
        [IO.File]::WriteAllText((Join-Path $repository 'new.cs'), 'class Added {}')
        foreach ($name in @('bin', 'obj', '.bootstrap')) {
            $directory = Join-Path $repository $name
            [IO.Directory]::CreateDirectory($directory) | Out-Null
            [IO.File]::WriteAllText((Join-Path $directory 'ignored.txt'), 'not source')
        }
        $files = @(Get-LocalBaselineSourceFiles $repository)
        $files | Should -Contain 'tracked.cs'
        $files | Should -Contain 'new.cs'
        @($files | Where-Object { $_ -match 'ignored\.txt' }).Count | Should -Be 0
    }

    It 'rejects a tracked missing file instead of relying on a past build' {
        [IO.File]::Delete((Join-Path $repository 'tracked.cs'))
        { Get-LocalBaselineSourceFiles $repository } | Should -Throw '*Authored source entry is absent*'
    }

    It 'rejects generated output even when somebody force-adds it' {
        [IO.Directory]::CreateDirectory((Join-Path $repository 'bin')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $repository 'bin\generated.dll'), 'not a source baseline')
        & git -C $repository add --force -- bin/generated.dll
        if ($LASTEXITCODE -ne 0) { throw 'Local test setup failed.' }
        { Get-LocalBaselineSourceFiles $repository } | Should -Throw '*Generated, operational or unsafe*'
    }

    It 'rejects local authentication and browser output before creating a snapshot' -ForEach @(
        @{ Relative = '.temp_secret'; Tracked = $false },
        @{ Relative = '.temp_secret'; Tracked = $true },
        @{ Relative = '.playwright-mcp\page.yml'; Tracked = $false },
        @{ Relative = '.playwright-mcp\page.yml'; Tracked = $true }
    ) {
        $path = Join-Path $repository $Relative
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
        [IO.File]::WriteAllText($path, 'synthetic-private-fixture')
        if ($Tracked) {
            & git -C $repository add --force -- $Relative
            if ($LASTEXITCODE -ne 0) { throw 'Local test setup failed.' }
        }
        $target = Join-Path $repository '.test-work\copy\source'
        { New-LocalBaselineSnapshot $repository $target } | Should -Throw '*Generated, operational or unsafe*'
        Test-Path -LiteralPath $target | Should -BeFalse
    }

    It 'keeps the supplied local credential and browser output out of the source inventory' {
        $ignore = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\..\.gitignore'))
        [IO.File]::WriteAllText((Join-Path $repository '.gitignore'), $ignore)
        [IO.File]::WriteAllText((Join-Path $repository '.temp_secret'), 'synthetic-private-fixture')
        $browser = Join-Path $repository '.playwright-mcp'
        [IO.Directory]::CreateDirectory($browser) | Out-Null
        [IO.File]::WriteAllText((Join-Path $browser 'page.yml'), 'synthetic-private-fixture')
        $files = @(Get-LocalBaselineSourceFiles $repository)
        $files | Should -Not -Contain '.temp_secret'
        $files | Should -Not -Contain '.playwright-mcp/page.yml'
        $files | Should -Contain 'tracked.cs'
    }

    It 'copies exact current source into a new clean directory' {
        $target = Join-Path $repository '.test-work\copy\source'
        $manifest = @(New-LocalBaselineSnapshot $repository $target)
        $manifest.Count | Should -Be 2
        [IO.File]::ReadAllText((Join-Path $target 'tracked.cs')) | Should -BeExactly 'class Tracked {}'
        Test-Path -LiteralPath (Join-Path $target '.git') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $target 'bin') | Should -BeFalse
        { New-LocalBaselineSnapshot $repository $target } | Should -Throw '*must be new*'
    }

    It 'rejects paths outside the explicitly owned source root' {
        { Assert-LocalBaselineUnlinkedPath (Join-Path $repository '..\elsewhere') $repository } |
            Should -Throw '*escaped*'
    }

    It 'rejects source drift after a clean snapshot instead of accepting stale test results' {
        $manifest = @(New-LocalBaselineSnapshot $repository (Join-Path $repository '.test-work\copy\source'))
        Assert-LocalBaselineSourceUnchanged $repository $manifest
        [IO.File]::WriteAllText((Join-Path $repository 'tracked.cs'), 'class Changed {}')
        { Assert-LocalBaselineSourceUnchanged $repository $manifest } | Should -Throw '*Source changed*'
    }

    It 'rejects newly authored files added after the snapshot' {
        $manifest = @(New-LocalBaselineSnapshot $repository (Join-Path $repository '.test-work\copy\source'))
        [IO.File]::WriteAllText((Join-Path $repository 'later.cs'), 'class Later {}')
        { Assert-LocalBaselineSourceUnchanged $repository $manifest } | Should -Throw '*source inventory changed*'
    }

    It 'parses scripts without executing their provider commands' {
        [IO.File]::WriteAllText((Join-Path $repository 'parse-only.ps1'), "throw 'This must never execute'; az group delete --name unsafe")
        $manifest = @([pscustomobject]@{ path = 'parse-only.ps1' })
        Test-LocalBaselinePowerShellSyntax $repository $manifest | Should -Be 1
    }

    It 'reports invalid script syntax as failure' {
        [IO.File]::WriteAllText((Join-Path $repository 'invalid.ps1'), 'function Broken {')
        $manifest = @([pscustomobject]@{ path = 'invalid.ps1' })
        { Test-LocalBaselinePowerShellSyntax $repository $manifest } | Should -Throw '*PowerShell syntax failed*'
    }

    It 'will not recursively clean an unowned directory or repository root' {
        { Remove-LocalBaselineWorkspace $repository $repository } | Should -Throw '*Cleanup refused*'
        $work = Join-Path $repository ".test-work\m1-$([guid]::NewGuid().ToString('N'))"
        [IO.Directory]::CreateDirectory($work) | Out-Null
        { Remove-LocalBaselineWorkspace $work $repository } | Should -Throw '*ownership marker*'
    }

    It 'cleans only the exact run with its matching ownership marker' {
        $name = "m1-$([guid]::NewGuid().ToString('N'))"
        $work = Join-Path $repository ".test-work\$name"
        [IO.Directory]::CreateDirectory($work) | Out-Null
        [IO.File]::WriteAllText((Join-Path $work '.local-baseline-owner'), $name)
        Remove-LocalBaselineWorkspace $work $repository
        Test-Path -LiteralPath $work | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $repository 'tracked.cs') | Should -BeTrue
    }

    It 'accepts only a nonempty fully executed passing test result' {
        $path = Join-Path $TestDrive 'passed.trx'
        [IO.File]::WriteAllText($path, '<TestRun><ResultSummary><Counters total="3" executed="3" passed="3" failed="0" notExecuted="0" /></ResultSummary></TestRun>')
        Assert-LocalBaselineTestResult $path | Should -Be 3
    }

    It 'rejects zero, skipped and failed test results' -ForEach @(
        @{ Total = 0; Executed = 0; Passed = 0; Failed = 0; NotExecuted = 0 },
        @{ Total = 3; Executed = 2; Passed = 2; Failed = 0; NotExecuted = 1 },
        @{ Total = 3; Executed = 3; Passed = 2; Failed = 1; NotExecuted = 0 }
    ) {
        $path = Join-Path $TestDrive 'not-passed.trx'
        [IO.File]::WriteAllText($path, "<TestRun><ResultSummary><Counters total=`"$Total`" executed=`"$Executed`" passed=`"$Passed`" failed=`"$Failed`" notExecuted=`"$NotExecuted`" /></ResultSummary></TestRun>")
        { Assert-LocalBaselineTestResult $path } | Should -Throw '*must all execute and pass*'
    }

    It 'never selects the real SQL project for the default local suite' {
        $selection = @(Get-LocalBaselineTestSelection)
        $selection.Count | Should -Be 6
        $selection.Name | Should -Not -Contain 'Gateway.IntegrationTests'
        $selection.Name | Should -Contain 'Gateway.Tooling.Tests'
        @($selection | Where-Object Sql).Count | Should -Be 0
    }

    It 'selects the dedicated SQL project only with the explicit option' {
        $selection = @(Get-LocalBaselineTestSelection -IncludeSql)
        $selection.Count | Should -Be 7
        $sql = @($selection | Where-Object Sql)
        $sql.Count | Should -Be 1
        $sql[0].Name | Should -BeExactly 'Gateway.IntegrationTests'
    }
}
