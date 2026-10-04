#Requires -Version 7.0
# Thin transport for graphical setup. Provisioning remains in bootstrap.ps1.
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Inspect','Save','SignIn')][string]$Action)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
foreach ($name in @('Common','Experience','Runtime','Lifecycle')) {
    Import-Module "$PSScriptRoot/modules/$name.psm1" -Force -DisableNameChecking
}
$lease=$null
$temporary=$null
try {
    $configurationPath=Join-Path $PSScriptRoot 'config.json'
    if ($Action -eq 'Inspect') {
        $configuration=$null
        if (Test-Path -LiteralPath $configurationPath) {
            $null=Read-BootstrapConfig -Path $configurationPath
            $configuration=Get-Content -LiteralPath $configurationPath -Raw | ConvertFrom-Json
        }
        $account=$null
        try { $account=Invoke-GatewayAzJson -Arguments @('account','show','--query','{tenantId:tenantId,subscriptionId:id,name:name}') } catch { }
        $data=@{configuration=$configuration;account=$account;platform=@{windows=[bool]$IsWindows};schema=(Get-Content "$PSScriptRoot/config.schema.json" -Raw | ConvertFrom-Json)}
    } else {
        $lease=Enter-GatewaySetupLock
        $inputText=[Console]::In.ReadToEnd()
        if ([Text.Encoding]::UTF8.GetByteCount($inputText) -gt 32768) { throw 'Setup input is too large.' }
        $inputObject=ConvertFrom-Json -InputObject $inputText -Depth 20
        if ($Action -eq 'SignIn') {
            Assert-GuidValue -Value $inputObject.tenantId -Label 'Microsoft tenant'
            & az login --tenant ([guid]$inputObject.tenantId).ToString('D') --allow-no-subscriptions --output none --only-show-errors *> $null
            if ($LASTEXITCODE -ne 0) { throw 'Microsoft sign-in did not complete. Retry sign-in in the browser.' }
            $data=@{signedIn=$true}
        } else {
            $temporary=Join-Path $PSScriptRoot ('.setup-'+[guid]::NewGuid().ToString('N')+'.tmp')
            [IO.File]::WriteAllText($temporary,$inputText)
            $null=Read-BootstrapConfig -Path $temporary
            [IO.File]::Move($temporary,$configurationPath,$true)
            $data=@{saved=$true;configurationFileFingerprint=(Get-BootstrapByteFingerprint -Bytes ([IO.File]::ReadAllBytes($configurationPath)))}
        }
    }
    [Console]::Out.WriteLine((@{type='Setup';data=$data} | ConvertTo-Json -Depth 45 -Compress))
} catch {
    # Configuration is non-secret, but validation may quote submitted values.
    # Return fixed guidance instead of arbitrary exception/provider text.
    $message=switch($Action) {
        'Save' {'Settings could not be saved. Check required fields, distinct ports, consent choices and the configuration schema. Another installer may also be using this checkout.'}
        'SignIn' {'Microsoft sign-in did not complete. Check the tenant ID and finish the official browser sign-in, then retry.'}
        default {'Setup could not read the current configuration. Run gateway doctor in the terminal to check this checkout.'}
    }
    [Console]::Out.WriteLine((@{type='Warning';message=$message;data=@{step=$Action}} | ConvertTo-Json -Compress))
    exit 1
} finally {
    if ($temporary -and (Test-Path -LiteralPath $temporary)) { Remove-Item -LiteralPath $temporary }
    if ($null -ne $lease) {$lease.Dispose()}
}
