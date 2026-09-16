#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'GatewayUpgrade.psm1')

function Assert-GatewayUpgradeSqlAdmission {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Database,
        [ValidateSet('CoreToFull', 'SourceOnlyFull')][string]$Mode = 'CoreToFull'
    )
    $required = @(
        '20260910_capability_preparation_receipts.sql'
        '20260910_purview_configuration_intent.sql'
        '20260910_purview_runtime_tests.sql'
        '20260911_prompt_receipt_protection_context.sql'
    )
    & (Get-Module GatewayUpgrade) {
        param($source, $database, $required, $mode)
        $manifest = Get-GatewayUpgradeMigratorManifest $source
        if ($manifest.status -cne 'Bound' -or -not $database.Contains('scripts') -or
            $database.scripts -isnot [array] -or $database.scripts.Count -gt 32) {
            throw 'UpgradeSqlAdmission: a bound migrator and complete SQL manifest are required.'
        }
        $registeredRequired = @($manifest.prepareScripts | Where-Object { $_ -cin $required })
        if (($registeredRequired -join '|') -cne ($required -join '|')) {
            throw 'UpgradeSqlAdmission: the candidate migrator omits or reorders required current SQL.'
        }
        if ($mode -ceq 'SourceOnlyFull') {
            Assert-GatewayUpgradeHash $database.currentSchemaFingerprint
            Assert-GatewayUpgradeHash $database.targetModelFingerprint
            if ($database.scripts.Count -ne 0 -or $database.currentSchemaFingerprint -cne $database.targetSchemaFingerprint) {
                throw 'UpgradeSqlAdmission: SourceOnlyFull requires no SQL and an exact unchanged physical schema.'
            }
            return
        }
        $names = [Collections.Generic.List[string]]::new()
        foreach ($entry in $database.scripts) {
            if ($entry -isnot [Collections.IDictionary] -or $entry.Count -ne 3 -or
                -not $entry.Contains('path') -or -not $entry.Contains('sha256') -or
                -not $entry.Contains('classification') -or $entry.classification -cne 'Additive' -or
                $entry.path -cnotmatch '^infrastructure\\sql\\[0-9]{8}_[a-z0-9_]+\.sql$' -or
                $entry.sha256 -cnotmatch '^sha256:[0-9a-f]{64}$') {
                throw 'UpgradeSqlAdmission: malformed SQL path/checksum binding.'
            }
            $name = [IO.Path]::GetFileName($entry.path)
            if ($names.Contains($name) -or $name -cnotin $manifest.prepareScripts) {
                throw 'UpgradeSqlAdmission: duplicate or unregistered SQL.'
            }
            $file = Resolve-GatewayUpgradeFile $source $entry.path
            if ((Get-GatewayUpgradeFileHash $file) -cne $entry.sha256) {
                throw 'UpgradeSqlAdmission: approved SQL bytes changed.'
            }
            $names.Add($name)
        }
        $selectedRequired = @($names | Where-Object { $_ -cin $required })
        $ordered = @($manifest.prepareScripts | Where-Object { $_ -cin $names })
        if (($selectedRequired -join '|') -cne ($required -join '|') -or
            ($ordered -join '|') -cne ($names -join '|')) {
            throw 'UpgradeSqlAdmission: every required current migration must be selected in reviewed order, even with review/artifact approval.'
        }
    } $SourceRoot $Database $required $Mode
}

Export-ModuleMember -Function Assert-GatewayUpgradeSqlAdmission
