BeforeAll {
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    Import-Module (Join-Path $root 'bootstrap/modules/Common.psm1') -Force -DisableNameChecking
}
Describe 'Windows executor packaging source identity' {
    It 'binds the packaging script and detects an implementation change' {
        $repository = Join-Path $TestDrive 'package-source'
        [IO.Directory]::CreateDirectory((Join-Path $repository 'src')) | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $repository 'operations')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $repository 'src/program.cs'), '// source fixture')
        $builder = Join-Path $repository 'operations/build-purview-executor-package.ps1'
        [IO.File]::WriteAllText($builder, '# package builder fixture')
        $before = Get-BootstrapSourceFingerprint -Root $repository
        @(Get-BootstrapSourceManifest -Root $repository | ForEach-Object path) |
            Should -Contain 'operations/build-purview-executor-package.ps1'
        [IO.File]::AppendAllText($builder, '# changed builder')
        Get-BootstrapSourceFingerprint -Root $repository | Should -Not -BeExactly $before
    }
    It 'does not include unrelated operator scripts in deployment source' {
        $repository = Join-Path $TestDrive 'unrelated-operation'
        [IO.Directory]::CreateDirectory((Join-Path $repository 'src')) | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $repository 'operations')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $repository 'src/program.cs'), '// source fixture')
        $before = Get-BootstrapSourceFingerprint -Root $repository
        [IO.File]::WriteAllText((Join-Path $repository 'operations/unrelated.ps1'), '# unrelated fixture')
        Get-BootstrapSourceFingerprint -Root $repository | Should -BeExactly $before
    }
}