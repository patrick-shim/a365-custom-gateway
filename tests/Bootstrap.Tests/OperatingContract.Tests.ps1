BeforeDiscovery {
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $paths = @(
        'AGENTS.md', 'CLAUDE.md', '.github/copilot-instructions.md',
        'README.md', 'bootstrap/README.md', 'docs/agent-continuation.md',
        'docs/implementation-status.md'
    )
    $paths += @(Get-ChildItem -LiteralPath (Join-Path $root '.claude/agents') -Filter '*.md' -File |
        ForEach-Object { [IO.Path]::GetRelativePath($root, $_.FullName) })
    $paths += @(Get-ChildItem -LiteralPath (Join-Path $root '.codex/agents') -Filter '*.toml' -File |
        ForEach-Object { [IO.Path]::GetRelativePath($root, $_.FullName) })
    foreach ($directory in @('.agents/skills', '.claude/skills')) {
        $paths += @(Get-ChildItem -LiteralPath (Join-Path $root $directory) -Recurse -Filter 'SKILL.md' -File |
            ForEach-Object { [IO.Path]::GetRelativePath($root, $_.FullName) })
    }
    $paths += @(Get-ChildItem -LiteralPath (Join-Path $root '.agents/skills') -Recurse -Filter 'openai.yaml' -File |
        ForEach-Object { [IO.Path]::GetRelativePath($root, $_.FullName) })
    foreach ($directory in @('docs/agent-guides', 'docs/operations',
            '.agents/skills/a365-bootstrap-delivery/references')) {
        $paths += @(Get-ChildItem -LiteralPath (Join-Path $root $directory) -Filter '*.md' -File |
            Where-Object Name -ne 'end-to-end-execution.md' |
            ForEach-Object { [IO.Path]::GetRelativePath($root, $_.FullName) })
    }
    $contracts = @($paths | Sort-Object -Unique | ForEach-Object { @{ Path = $_; Root = $root } })
}

Describe 'Durable end-to-end operating contract wiring' {
    It 'requires the canonical execution contract in <Path>' -ForEach $contracts {
        $file = Join-Path $Root $Path
        $source = Get-Content -LiteralPath $file -Raw
        $source | Should -Match 'end-to-end-execution\.md'
        foreach ($link in [regex]::Matches($source, '\]\(([^)\s]*end-to-end-execution\.md)\)')) {
            $resolved = [IO.Path]::GetFullPath((Join-Path (Split-Path $file -Parent) $link.Groups[1].Value))
            $resolved | Should -Be ([IO.Path]::GetFullPath((Join-Path $Root 'docs/agent-guides/end-to-end-execution.md')))
            Test-Path -LiteralPath $resolved -PathType Leaf | Should -BeTrue
        }
        if ($Path -like '*.toml') {
            $source | Should -Match '(?s)developer_instructions\s*=\s*""".*end-to-end-execution\.md.*"""'
        }
        if ($Path -like '*openai.yaml') {
            $source | Should -Match '(?s)default_prompt:\s*>-.*end-to-end-execution\.md'
        }
    }

    It 'keeps both model role catalogs and skill adapters aligned' {
        $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        $claude = @(Get-ChildItem (Join-Path $root '.claude/agents') -Filter '*.md' -File | Select-Object -ExpandProperty BaseName | Sort-Object)
        $codex = @(Get-ChildItem (Join-Path $root '.codex/agents') -Filter '*.toml' -File | Select-Object -ExpandProperty BaseName | Sort-Object)
        $claude.Count | Should -BeGreaterThan 0
        $codex | Should -Be $claude
        $canonical = @(Get-ChildItem (Join-Path $root '.agents/skills') -Directory | Select-Object -ExpandProperty Name | Sort-Object)
        $adapters = @(Get-ChildItem (Join-Path $root '.claude/skills') -Directory | Select-Object -ExpandProperty Name | Sort-Object)
        $adapters | Should -Be $canonical
    }

    It 'retains outcome, authority, credential, stop and completion distinctions' {
        $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        $source = Get-Content (Join-Path $root 'docs/agent-guides/end-to-end-execution.md') -Raw
        foreach ($required in @('independent live acceptance', 'Windows Setup UI',
                'safe screenshot', 'scratch', 'NoResponse', 'secure-input',
                'explicit stop', 'IndependentReview', 'Paused', 'Blocked',
                'user supplied credentials', 'never authorizes', 'current approved dependency order')) {
            $source | Should -Match ([regex]::Escape($required))
        }
    }

    It 'includes the canonical release gate and keeps all its relative links resolvable' {
        $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        $file = Join-Path $root 'docs/agent-guides/end-to-end-execution.md'
        $source = Get-Content $file -Raw
        foreach ($link in [regex]::Matches($source, '\]\(([^)\s]+\.md)\)')) {
            Test-Path -LiteralPath (Join-Path (Split-Path $file -Parent) $link.Groups[1].Value) -PathType Leaf |
                Should -BeTrue
        }
    }
}
