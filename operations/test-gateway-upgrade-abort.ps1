#Requires -Version 7.0
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$abort = Import-Module (Join-Path $PSScriptRoot 'GatewayUpgradeAbort.psm1') -Force -PassThru
Import-Module (Join-Path $PSScriptRoot 'GatewayUpgrade.psm1')
Import-Module (Join-Path $PSScriptRoot 'GatewayUpgradeJson.psm1')
$execution = Import-Module (Join-Path $PSScriptRoot 'GatewayUpgradeExecution.psm1') -Force -PassThru
$workspace = Join-Path $root ".maintenance\local-abort-tests\$([guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($workspace) | Out-Null
$script:passed = 0
function Check([bool]$Condition, [string]$Name) { if (-not $Condition) { throw "FAIL: $Name" }; $script:passed++ }
function Reject([scriptblock]$Action, [string]$Name) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Check $failed $Name
}
function Copy-Value($Value) { ConvertFrom-Json (ConvertTo-Json $Value -Depth 100) -AsHashtable -Depth 100 }
function Save-Fixture([string]$Path, $Value) {
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [IO.File]::WriteAllText($Path, (ConvertTo-Json $Value -Depth 100))
}
try {
    $fp='sha256:'+('a'*64); $stateHash='sha256:'+('b'*64)
    $owner='11111111-1111-4111-8111-111111111111'
    $prefix='/subscriptions/22222222-2222-4222-8222-222222222222/resourceGroups/rg-fixture-dev'
    $container="$prefix/providers/Microsoft.Storage/storageAccounts/fixture/blobServices/default/containers/gateway-upgrade-lock"
    $original=@{envelope=@{planFingerprint=$fp;plan=@{
        original=@{stateSha256=$stateHash;acceptedSourceFingerprint='sha256:'+('c'*64)}
        request=@{target=@{deploymentOwnershipId=$owner}}
        scope=@{resources=@(@{stage='Coordination';resourceId=$container})}
    }}}
    $directory=Join-Path $workspace ".maintenance\executions\$($fp.Substring(7))"
    $lease=@{schemaVersion=1;planFingerprint=$fp;leaseId='33333333-3333-4333-8333-333333333333'
        containerId=$container;ownerFingerprint=& $abort {Get-GatewayAbortOwner}}
    $metadata=@{gatewayowner=$owner;gatewaybootstrap=$original.envelope.plan.original.acceptedSourceFingerprint}
    Save-Fixture (Join-Path $directory 'lease.json') $lease
    foreach($kind in @('intent','result')) {
        $value=if($kind -ceq 'intent') {
            $input=@{id=$container;metadata=$metadata}
            @{input=$input;inputFingerprint=Get-GatewayUpgradeFingerprint $input;acceptedAtUtc='2026-01-01T00:00:00Z'}
        } else { @{id=$container;metadata=$metadata;publicAccess='None'} }
        $record=@{schemaVersion=1;planFingerprint=$fp;originalStateSha256=$stateHash;action='coordination-container';kind=$kind;value=$value}
        Save-Fixture (Join-Path $directory "actions\coordination-container\$kind.json") @{record=$record;fingerprint=Get-GatewayUpgradeFingerprint $record}
    }
    $binding=& $abort {param($o,$w) Get-GatewayAbortExecutionBinding $o $w} $original $workspace
    Check ($binding.inventory.Count -eq 3) 'exact checkpoint admitted'
    foreach($field in @('planFingerprint','ownerFingerprint','containerId','leaseId')) {
        $bad=Copy-Value $lease
        $bad[$field]=if($field -ceq 'leaseId') {'00000000-0000-0000-0000-000000000000'}else{'foreign'}
        Save-Fixture (Join-Path $directory 'lease.json') $bad
        Reject {& $abort {param($o,$w) Get-GatewayAbortExecutionBinding $o $w} $original $workspace} "wrong $field rejected"
    }
    Save-Fixture (Join-Path $directory 'lease.json') $lease
    foreach($extra in @('cutover-inventory.json','workload-baselines.json','acceptance.json','actions\sql-admin-delegate\intent.json',
        'actions\database-job\intent.json','actions\publisher-job\intent.json','actions\executor-source-cutover\intent.json')) {
        $path=Join-Path $directory $extra
        Save-Fixture $path @{}
        Reject {& $abort {param($o,$w) Get-GatewayAbortExecutionBinding $o $w} $original $workspace} "extra $extra rejected"
        Remove-Item -LiteralPath $path
        if($extra.StartsWith('actions\')) {Remove-Item -LiteralPath (Split-Path -Parent $path)}
    }
    $empty=Join-Path $directory 'unexpected-empty'
    [IO.Directory]::CreateDirectory($empty)|Out-Null
    Reject {& $abort {param($o,$w) Get-GatewayAbortExecutionBinding $o $w} $original $workspace} 'unexpected empty directory rejected'
    Remove-Item -LiteralPath $empty
    $resultPath=Join-Path $directory 'actions\coordination-container\result.json'
    $savedResult=Read-GatewayUpgradeJson $resultPath
    $bad=Copy-Value $savedResult
    $bad.record.value.publicAccess='Blob'
    Save-Fixture $resultPath $bad
    Reject {& $abort {param($o,$w) Get-GatewayAbortExecutionBinding $o $w} $original $workspace} 'tampered coordination result rejected'
    Save-Fixture $resultPath $savedResult

    $authority=@{originalPlanFingerprint=$fp;execution=$binding;driver=@{fingerprint='sha256:'+('d'*64)}}
    $evidence=Join-Path $workspace 'fixture-review-evidence.json'
    Save-Fixture $evidence @{fixtureOnly=$true;notAnApproval=$true}
    $review=@{schemaVersion=1;decision='ApprovedAbortBeforeCutover';reviewerModel='gpt-6-astra'
        authorityFingerprint=Get-GatewayUpgradeFingerprint $authority;originalPlanFingerprint=$fp
        driverFingerprint=$authority.driver.fingerprint;evidencePath=$evidence;evidenceSha256=Get-GatewayUpgradeFileHash $evidence}
    $reviewPath=Join-Path $workspace 'fixture-review.json'
    Save-Fixture $reviewPath $review
    $null=& $abort {param($p,$a,$w) Read-GatewayAbortReview $p $a $w} $reviewPath $authority $workspace
    Check $true 'separate exact review binding'
    foreach($field in @('decision','reviewerModel','authorityFingerprint','originalPlanFingerprint','driverFingerprint','evidenceSha256')) {
        $bad=Copy-Value $review; $bad[$field]='wrong'
        Save-Fixture $reviewPath $bad
        Reject {& $abort {param($p,$a,$w) Read-GatewayAbortReview $p $a $w} $reviewPath $authority $workspace} "wrong review $field rejected"
    }
    Save-Fixture $reviewPath $review
    $null=& $abort {param($a,$w) Read-GatewayAbortReview '' $a $w} $authority $workspace
    Check $true 'draft Plan has no fabricated review'
    $escape=Join-Path $root 'operations\GatewayUpgradeAbort.psm1'
    Reject {& $abort {param($p,$w) Resolve-GatewayAbortPath $p $w} $escape $workspace} 'cross-workspace evidence rejected'

    & (Get-Module GatewayUpgrade) {
        function script:Invoke-GatewayUpgradeBaselineProcess {param($Inputs) return @{status='Passed';fixtureOnly=$true}}
    }
    $boundaryChecks=& $abort {
        param($prefix,$container,$metadata,$owner)
        $api="$prefix/providers/Microsoft.App/containerApps/api"
        $worker="$prefix/providers/Microsoft.App/containerApps/worker"
        $admin="$prefix/providers/Microsoft.App/containerApps/admin"
        $q1="$prefix/providers/Microsoft.ServiceBus/namespaces/bus/queues/gateway-provisioning-v3"
        $q2="$prefix/providers/Microsoft.ServiceBus/namespaces/bus/queues/gateway-protection-admin-v1"
        $sql="$prefix/providers/Microsoft.Sql/servers/sql/administrators/ActiveDirectory"
        $job="$prefix/providers/Microsoft.App/jobs/job-fixture"
        $script:boundary=@{fault='';rulesShape='empty-rules';container=$container;metadata=$metadata;sql=$sql;owner=$owner;worker=$worker}
        function script:Invoke-GatewayAbortArm {
            param($Context,$Action,$ResourceId,$ApiVersion,[switch]$AllowNotFound)
            if($Action -cne 'GET'){throw 'fixture forbids writes'}
            if($ResourceId -ceq $script:boundary.container){
                return @{id=$(if($script:boundary.fault -eq 'foreign-container'){'foreign'}else{$ResourceId})
                    properties=@{publicAccess=$(if($script:boundary.fault -eq 'public-container'){'Blob'}else{'None'})
                        metadata=$(if($script:boundary.fault -eq 'foreign-owner'){@{gatewayowner='foreign'}}else{$script:boundary.metadata})
                        leaseState='Leased';leaseStatus='Locked';leaseDuration=$(if($script:boundary.fault -eq 'finite-lease'){'Fixed'}else{'Infinite'})}}
            }
            if($ResourceId -match '/jobs/'){
                if($script:boundary.fault -eq 'job'){return @{id=$ResourceId}}
                return $null
            }
            if($ResourceId -match '/deployments$'){
                return @{value=@(if($script:boundary.fault -eq 'deployment'){@{name='maintenance-database-job-aaaaaaaaaa'}})
                    nextLink=$(if($script:boundary.fault -eq 'pagination'){'https://unread-next-page'}else{$null})}
            }
            if($ResourceId -ceq $script:boundary.sql){
                return @{id=$ResourceId;properties=@{sid=$(if($script:boundary.fault -eq 'sql'){'foreign'}else{$script:boundary.owner})
                    login='original';tenantId=$script:boundary.owner}}
            }
            if($ResourceId -match '/queues/'){
                return @{id=$ResourceId;properties=@{status=$(if($script:boundary.fault -eq 'queue'){'ReceiveDisabled'}else{'Active'});messageCount=23}}
            }
            if($ResourceId -match '/containerApps/'){
                $validRule=@{name='existing-access';ipAddressRange='203.0.113.0/24';action='Allow'}
                $configuration=@{ingress=@{ipSecurityRestrictions=@()}}
                switch($script:boundary.rulesShape){
                    'actual-null' {
                        if($ResourceId -ceq $script:boundary.worker){$configuration=@{ingress=$null}}
                        else{$configuration.ingress.ipSecurityRestrictions=$null}
                    }
                    'missing-rules' {$configuration.ingress.Remove('ipSecurityRestrictions')}
                    'missing-ingress' {$configuration.Remove('ingress')}
                    'null-ingress' {$configuration.ingress=$null}
                    'valid-rule' {$configuration.ingress.ipSecurityRestrictions=@($validRule)}
                    'deny-rule' {$configuration.ingress.ipSecurityRestrictions=@(@{name='gateway-maintenance-deny';ipAddressRange='0.0.0.0/0';action='Deny'})}
                    'not-array' {$configuration.ingress.ipSecurityRestrictions=@{}}
                    'string-collection' {$configuration.ingress.ipSecurityRestrictions='invalid'}
                    'null-entry' {$configuration.ingress.ipSecurityRestrictions=@($null)}
                    'scalar-entry' {$configuration.ingress.ipSecurityRestrictions=@('invalid')}
                    'missing-name' {$configuration.ingress.ipSecurityRestrictions=@(@{ipAddressRange='0.0.0.0/0';action='Allow'})}
                    'invalid-name' {$configuration.ingress.ipSecurityRestrictions=@(@{name=4;ipAddressRange='0.0.0.0/0';action='Allow'})}
                    'missing-range' {$configuration.ingress.ipSecurityRestrictions=@(@{name='incomplete';action='Allow'})}
                    'invalid-action' {$configuration.ingress.ipSecurityRestrictions=@(@{name='incomplete';ipAddressRange='0.0.0.0/0';action=$null})}
                    'mixed-null' {$configuration.ingress.ipSecurityRestrictions=@($validRule,$null)}
                }
                if($script:boundary.fault -eq 'cutover'){
                    $configuration=@{ingress=@{ipSecurityRestrictions=@(@{name='gateway-maintenance-deny';ipAddressRange='0.0.0.0/0';action='Deny'})}}
                }
                return @{id=$(if($script:boundary.fault -eq 'foreign-app'){'foreign'}else{$ResourceId});identity=@{principalId=$script:boundary.owner};tags=@{}
                    properties=@{provisioningState=$(if($script:boundary.fault -eq 'app'){'Updating'}else{'Succeeded'})
                        environmentId='original';template=@{containers=@()};configuration=$configuration}}
            }
            throw 'fixture unexpected scope'
        }
        $context=@{authority=@{originalPlanFingerprint='sha256:'+('a'*64);state=@{path='fixture';sha256='fixture'};config=@{path='fixture';sha256='fixture'}
                execution=@{lease=@{containerId=$container};metadata=$metadata}}
            original=@{envelope=@{plan=@{request=@{target=@{tenantId=$owner}}
                cutover=@{ApiResourceId=$api;WorkerResourceId=$worker;ProvisioningQueueResourceId=$q1;ProtectionQueueResourceId=$q2}
                scope=@{resourceGroupId=$prefix;resources=@(@{stage='Admin';resourceId=$admin},@{stage='DatabaseExpand';resourceId=$job})
                    privilegedMutations=@(@{operation='TemporarySqlAdministratorDelegation';resourceId=$sql;restoreObjectId=$owner;restoreLogin='original'})}}}}}
        $result=Get-GatewayAbortLiveBoundary $context
        if($result.stable.Count -ne 6 -or $result.lease.state -cne 'leased'){throw 'fixture complete original boundary failed'}
        $count=1
        foreach($fault in @('job','deployment','pagination','sql','queue','app','cutover','foreign-app','foreign-container','foreign-owner','public-container','finite-lease')){
            $script:boundary.fault=$fault;$rejected=$false
            try{Get-GatewayAbortLiveBoundary $context|Out-Null}catch{$rejected=$true}
            if(-not $rejected){throw "real boundary accepted $fault"}
            $count++
        }
        $script:boundary.fault=''
        foreach($shape in @('actual-null','missing-rules','empty-rules','missing-ingress','null-ingress','valid-rule')){
            $script:boundary.rulesShape=$shape
            $result=Get-GatewayAbortLiveBoundary $context
            if($result.stable.Count -ne 6){throw "valid ingress shape $shape rejected"}
            $count++
        }
        foreach($shape in @('deny-rule','not-array','string-collection','null-entry','scalar-entry','missing-name','invalid-name','missing-range','invalid-action','mixed-null')){
            $script:boundary.rulesShape=$shape;$rejected=$false
            try{Get-GatewayAbortLiveBoundary $context|Out-Null}catch{$rejected=$true}
            if(-not $rejected){throw "malformed/held ingress shape $shape accepted"}
            $count++
        }
        return $count
    } $prefix $container $metadata $owner
    $script:passed+=$boundaryChecks

    $authorityChecks=& $abort {
        $manifest=@(@{path='fixture';sha256='sha256:'+('a'*64)})
        $a=@{originalPlan=@{path='fixture'};originalPlanFingerprint='sha256:'+('a'*64);state=@{path='fixture'};config=@{path='fixture'}
            candidateSourceFingerprint='sha256:'+('b'*64);driver=@{manifest=$manifest;fingerprint=Get-GatewayUpgradeFingerprint $manifest}}
        $context=@{authority=$a;workspace='fixture';abortPlan=@{review=@{file=@{path='fixture'};record=@{fixtureOnly=$true}}}}
        $script:authFixture=@{manifest=$manifest;binding=$a;fault='';review=$context.abortPlan.review}
        function script:Get-GatewayAbortToolManifest {return ,$script:authFixture.manifest}
        function script:Test-GatewayUpgradeAbortOriginalPlan {param($a,$b,$c,$d,$e) return @{envelope=@{plan=@{}}}}
        function script:Get-GatewayAbortBinding {
            param($o,$w)
            $value=ConvertFrom-Json (ConvertTo-Json $script:authFixture.binding -Depth 30) -AsHashtable
            if($script:authFixture.fault -eq 'source'){$value.candidateSourceFingerprint='changed'}
            return $value
        }
        function script:Assert-GatewayUpgradeCurrentOperator {param($p) if($script:authFixture.fault -eq 'operator'){throw 'fixture exact operator differs'}}
        function script:Read-GatewayAbortReview {
            param($p,$a,$w)
            if($script:authFixture.fault -eq 'review'){return @{foreign='review'}}
            return $script:authFixture.review
        }
        Assert-GatewayAbortAuthority $context
        $count=1
        foreach($fault in @('source','operator','review')){
            $script:authFixture.fault=$fault;$rejected=$false
            try{Assert-GatewayAbortAuthority $context}catch{$rejected=$true}
            if(-not $rejected){throw "abort authority accepted $fault"}
            $count++
        }
        $script:authFixture.fault='';$script:authFixture.manifest=@(@{path='changed';sha256='sha256:'+('b'*64)})
        $rejected=$false;try{Assert-GatewayAbortAuthority $context}catch{$rejected=$true}
        if(-not $rejected){throw 'changed driver accepted'}
        return ($count+1)
    }
    $script:passed+=$authorityChecks

    # All provider/authority hooks below are local fixtures, never live transports.
    $checks=& $abort {
        param($workspace,$authority,$original)
        $script:fixture=@{fault='';calls=[Collections.Generic.List[string]]::new();lease=@{state='leased';status='locked'};checks=0;stable=@{apps='original';queues='Active';sql='original'}}
        function script:Assert-GatewayAbortAuthority {param($Context) $script:fixture.checks++;if($script:fixture.fault -eq 'authority'){throw 'fixture authority rejected'}}
        function script:Get-GatewayAbortLiveBoundary {
            param($Context)
            if($script:fixture.fault -cin @('cutover','sql','job','baseline')) {throw 'fixture independent boundary rejected'}
            return @{baseline=@{status='Passed';fixtureOnly=$true};stable=$script:fixture.stable;lease=$script:fixture.lease}
        }
        function script:Get-GatewayAbortLeaseState {param($Context) return $script:fixture.lease}
        function script:Invoke-GatewayAbortArm {
            param($Context,$Action,$ResourceId,$ApiVersion)
            $script:fixture.calls.Add($Action)
            if($Action -cnotin @('Renew','Release') -or $ResourceId -cne $Context.authority.execution.lease.containerId) {throw 'fixture illegal mutation'}
            if($Action -ceq 'Renew') {
                if($script:fixture.fault -cin @('renew','foreign-lease')) {throw 'fixture unknown renew / foreign lease'}
                return @{leaseId=$Context.authority.execution.lease.leaseId}
            }
            if($script:fixture.fault -eq 'release-before') {throw 'fixture release unknown and still held'}
            $script:fixture.lease=@{state='available';status='unlocked'}
            if($script:fixture.fault -eq 'release-after') {throw 'fixture release succeeded but response lost'}
            if($script:fixture.fault -eq 'new-lease') {$script:fixture.lease=@{state='leased';status='locked'}}
            return @{}
        }
        $count=0
        foreach($fault in @('','authority','cutover','sql','job','baseline','foreign-lease','renew','release-before','release-after','new-lease')) {
            $script:fixture.fault=$fault;$script:fixture.calls.Clear();$script:fixture.lease=@{state='leased';status='locked'}
            $context=@{workspace=$workspace;authority=$authority;original=$original
                abortPlanFingerprint='sha256:'+('e'*64);abortPlan=@{observations=@{stable=@{apps='original';queues='Active';sql='original'}}}
                journal=Join-Path $workspace ("journals\"+$(if($fault){$fault}else{'success'}))}
            $failed=$false
            try {$result=Invoke-GatewayAbortLeaseLifecycle $context}catch{$failed=$true}
            if($fault -eq '') {
                if($failed -or $result.status -cne 'AbortBeforeCutoverVerified' -or ($script:fixture.calls -join '|') -cne 'Renew|Release') {throw 'fixture successful abort failed'}
                $prior=$script:fixture.calls.Count
                $result=Invoke-GatewayAbortLeaseLifecycle $context -Reconcile
                if($script:fixture.calls.Count -ne $prior -or $result.disposition -cne 'ExistingTerminalEvidence'){throw 'terminal caused mutation'}
                $count+=2
            } else {
                if(-not $failed){throw "fault $fault accepted"}
                $prior=$script:fixture.calls.Count;$script:fixture.fault=''
                $reconciled=$false
                try {$r=Invoke-GatewayAbortLeaseLifecycle $context -Reconcile;$reconciled=$true}catch{}
                if($script:fixture.calls.Count -ne $prior){throw "fault $fault caused replay"}
                if(($fault -ceq 'release-after') -ne $reconciled){throw "fault $fault reconciliation disposition differs"}
                $count+=2
            }
        }
        $context=@{workspace=$workspace;authority=$authority;original=$original;abortPlanFingerprint='sha256:'+('e'*64)
            abortPlan=@{observations=@{stable=@{apps='original'}}};journal=Join-Path $workspace 'journals\drift'}
        $failed=$false
        try {Invoke-GatewayAbortLeaseLifecycle $context}catch{$failed=$true}
        if(-not $failed){throw 'live drift accepted'}
        $count++
        [IO.Directory]::CreateDirectory($context.journal)|Out-Null
        $failed=$false;try{Read-GatewayAbortJournal $context}catch{$failed=$true}
        if(-not $failed){throw 'empty partial journal accepted'}
        $count++
        foreach($state in @('available','expired','broken')){
            $script:fixture.calls.Clear();$script:fixture.lease=@{state=$state;status='unlocked'}
            $context.abortPlan.observations.stable=$script:fixture.stable
            $context.journal=Join-Path $workspace "journals\not-held-$state"
            $failed=$false;try{Invoke-GatewayAbortLeaseLifecycle $context}catch{$failed=$true}
            if(-not $failed -or $script:fixture.calls.Count -ne 0 -or (Test-Path -LiteralPath $context.journal)){throw "unexpected $state lease was acquired/adopted"}
            $count++
        }
        return $count
    } $workspace $authority $original
    $script:passed+=$checks

    $marker=Join-Path $workspace ".maintenance\abort-state\$($fp.Substring(7))"
    & $execution {param($w,$f) Assert-GatewayUpgradeNoAbortMarker $w $f} $workspace $fp
    Check $true 'unaborted Plan not blocked'
    [IO.Directory]::CreateDirectory($marker)|Out-Null
    foreach($mode in @('Build','Execute','Rollback','RestoreSqlAdministrator')) {
        Reject {Invoke-GatewayUpgradePipeline -Mode $mode -Envelope @{} -ExpectedPlanFingerprint $fp -StatePath '' -ConfigPath '' -WorkspaceRoot $workspace} "abort marker blocks $mode before other dispatch"
    }
    Reject {& $execution {param($d,$f) Enter-GatewayUpgradeCloudLease @{directory=$d;planFingerprint=$f}} $directory $fp} 'abort marker prevents lease reacquisition'

    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'GatewayUpgradeExecution.psm1'),[ref]$tokens,[ref]$errors)
    $assignment=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$contentRole'},$true))
    Check ($assignment.Count -eq 1) 'one exact Content Safety role filter'
    $filter=[scriptblock]::Create($assignment[0].Right.Extent.Text)
    $scope=@{retained=@{contentSafetyAccountId="$prefix/providers/Microsoft.CognitiveServices/accounts/cs-fixture"}}
    $Context=@{runtime=@{apiPrincipalId=$owner}}
    $roles=@(@{scope=$scope.retained.contentSafetyAccountId.Replace('/resourceGroups/','/resourcegroups/');principalId=$owner
        roleDefinitionId='/subscriptions/22222222-2222-4222-8222-222222222222/providers/Microsoft.Authorization/roleDefinitions/a97b65f3-24c7-4388-baec-2e87135dc908';condition=$null})
    Check (@(& $filter).Count -eq 1) 'ARM casing variant accepted without granting'
    $roles[0].scope+='-foreign'
    Check (@(& $filter).Count -eq 0) 'different ARM resource rejected'

    $timestamp='2026-09-14T00:25:35.3464147+08:00'
    $armJson='{"timestamp":"2026-09-14T00:25:35.3464147+08:00","nested":{"cpu":1.0,"items":[],"optional":null}}'
    $parsed=ConvertFrom-GatewayUpgradeArmJson -Json $armJson
    Check ($parsed.timestamp -is [string] -and $parsed.timestamp -ceq $timestamp) 'ARM timestamp spelling and offset preserved'
    Check ($null -eq $parsed.nested.optional -and $parsed.nested.items.Count -eq 0) 'ARM null and empty array preserved'
    Check ($parsed.nested.cpu -eq 1.0) 'ARM numeric value preserved'
    $planValue=@{schemaVersion=1;observations=@{stable=@{resource=$parsed}}}
    $planEnvelope=@{plan=$planValue;abortPlanFingerprint=Get-GatewayUpgradeFingerprint $planValue}
    $roundTripPath=Join-Path $workspace 'arm-roundtrip-plan.json'
    Save-Fixture $roundTripPath $planEnvelope
    $roundTrip=Read-GatewayUpgradeJson $roundTripPath
    Check ((Get-GatewayUpgradeFingerprint $roundTrip.plan) -ceq $planEnvelope.abortPlanFingerprint) 'real ARM parser preserves Plan fingerprint after file roundtrip'
    $journalContext=@{workspace=$workspace;journal=Join-Path $workspace 'arm-roundtrip-journal'
        authority=@{originalPlanFingerprint=$fp};abortPlanFingerprint='sha256:'+('f'*64)}
    $journalExact=& $abort {
        param($c,$value)
        Write-GatewayAbortRecord $c 'intent.json' $value
        $journal=Read-GatewayAbortJournal $c
        return (Get-GatewayUpgradeFingerprint $journal['intent.json']) -ceq (Get-GatewayUpgradeFingerprint $value)
    } $journalContext $parsed
    Check $journalExact 'real ARM parser preserves durable journal fingerprint'
    foreach($invalid in @('null','[]','"scalar"','{"x":1,"X":2}','{"x":1e200}','{invalid')) {
        Reject {ConvertFrom-GatewayUpgradeArmJson -Json $invalid} 'invalid, duplicate or unsupported ARM JSON rejected'
    }
    foreach($file in @('GatewayUpgradeAbort.psm1','GatewayUpgradeExecution.psm1')) {
        $readerAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $file),[ref]$tokens,[ref]$errors)
        $calls=@($readerAst.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -ceq 'ConvertFrom-GatewayUpgradeArmJson'},$true))
        Check ($calls.Count -eq 1) "$file uses the literal-preserving shared ARM reader"
    }
    Write-Output "PASS: $script:passed abort lifecycle/authority/inventory/terminal/role-case checks; fixtures only, no provider or lease calls."
} finally {
    if(Test-Path -LiteralPath $workspace){Remove-Item -LiteralPath $workspace -Recurse -Force}
}
