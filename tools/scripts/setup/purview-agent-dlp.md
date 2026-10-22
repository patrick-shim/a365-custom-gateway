# 개별 Agent ID용 Purview DLP 정책 만들기

`New-PurviewAgentDlpPolicy.ps1` 파일 하나를 로컬 Windows PC의 원하는 폴더에
복사해서 실행합니다. Gateway 실행, Docker, Gateway 키, bootstrap 설정은 필요하지
않습니다. 이미 Purview에 등록한 SIT를 사용해 **새 정책과 규칙**을 만듭니다.
SIT XML 자체를 가져오거나 기존 정책을 수정하는 스크립트는 아닙니다.

## 공식 구성 경로

Microsoft는 custom AI 앱의 DLP 연동 테스트 정책을 PowerShell로 구성하도록
[안내](https://learn.microsoft.com/en-us/purview/developer/configurepurview)하고,
[공식 예제](https://github.com/microsoft/purview-api-samples/blob/main/DLPforCustomAIApps/Create-DlpPolicyForCustomAIApps.ps1)에서
`EnforcementPlanes = Application`과 Entra Application ID를 사용합니다.
이 스크립트는 그 정책 형식을 개별 Entra agent에 적용합니다.

포털의 `Managed cloud apps`라는 이름만으로 적용 경로를 판단하지 않습니다.
현재 문서에서는 [Edge 브라우저 보호](https://learn.microsoft.com/en-us/purview/dlp-browser-dlp-learn)에도
사용되는 이름이며, UI의 비활성화 원인은 스크린샷만으로 확인할 수 없습니다.
여기서는 agent의 Graph `processContent` 연동을 위한 Application 정책을 만듭니다.
UI 지원 여부와 관계없이 서비스 권한과 해당 기능의 테넌트 사용 조건은 충족해야 합니다.

## 준비

PowerShell 7의 새 창을 사용합니다. 모듈은 처음 한 번 설치합니다.

```powershell
Install-Module ExchangeOnlineManagement -Scope CurrentUser
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
```

- Purview DLP 정책/규칙 작성 권한이 있는 관리자 계정이 필요합니다.
- agent 조회에는 delegated `Application.Read.All` 동의와 해당 agent 읽기 권한이
  필요합니다. Graph의 [agent 조회 권한](https://learn.microsoft.com/en-us/graph/api/agentidentity-get?view=graph-rest-1.0)을
  확인합니다. 스크립트는 권한을 부여하거나 Entra 객체를 변경하지 않습니다.
- Graph와 Purview 로그인에서 동일한 테넌트/계정을 사용합니다. 기존 연결이 있으면
  중단하므로 새 PowerShell 프로세스에서 실행합니다. 로그인은 각각 필요할 수 있습니다.
- `AgentApplicationId`: **개별 agent의 Application (client) ID**입니다. Gateway의
  외부 agent 문자열 ID, Object ID, Registry ID, 공유 Blueprint ID가 아닙니다.
- `BlueprintApplicationId`: 해당 agent가 속한 Blueprint의 Application ID입니다.
  관계 검증에만 사용하며 정책의 대상으로 넣지 않습니다.
- SIT는 이미 같은 테넌트에 게시되어 있어야 합니다. 중복 이름은 GUID로 선택합니다.

## 1. 기존 SIT 확인

아래 명령은 스크립트 파일이 있는 폴더에서 실행합니다. `<...>`를 실제 값으로 바꿉니다.

```powershell
.\New-PurviewAgentDlpPolicy.ps1 `
  -TenantId '<tenant-guid>' `
  -UserPrincipalName 'admin@your-tenant.onmicrosoft.com' `
  -ListSensitiveInformationTypes
```

## 2. 만들 내용 미리보기

```powershell
$settings = @{
    TenantId                 = '<tenant-guid>'
    UserPrincipalName        = 'admin@your-tenant.onmicrosoft.com'
    AgentApplicationId       = '<individual-agent-application-guid>'
    BlueprintApplicationId   = '<blueprint-application-guid>'
    PolicyName               = 'Agent SIT protection'
    RuleName                 = 'Agent SIT block'
    SensitiveInformationType = @('<existing-sit-guid-or-exact-name>')
    MinimumCount             = 1
    MinimumConfidence        = 85
    Mode                     = 'Enable'
}
.\New-PurviewAgentDlpPolicy.ps1 @settings
```

이 단계는 로그인과 조회만 합니다. 대상 agent와 Blueprint 관계, 테넌트, SIT,
동일 이름의 정책/규칙 존재 여부를 확인하고 생성할 범위를 보여줍니다.
여러 SIT를 배열로 넣으면 하나 이상이 조건에 맞을 때 규칙이 적용됩니다.
최소 건수와 신뢰도는 선택한 모든 SIT에 공통으로 적용됩니다.

## 3. 새 정책 생성

미리보기의 대상과 SIT를 확인한 뒤 동일한 설정으로 실행합니다.

```powershell
.\New-PurviewAgentDlpPolicy.ps1 @settings -Apply
```

`-Apply -WhatIf`도 실제 생성 없이 확인할 수 있습니다. SCC 명령 자체의 `-WhatIf`는
[지원되지 않으므로](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-dlpcompliancepolicy?view=exchange-ps#-whatif)
이 스크립트가 변경 호출 전 직접 차단합니다.

정책은 우선 `Disable`로 생성하고, 기존 SIT를 사용하는 규칙의 `UploadText`와
`DownloadText`에 `Block`을 지정합니다. 저장된 대상/규칙을 다시 읽어 확인한 후
요청한 모드로 변경합니다. 기본 `Enable`은 차단을 요청하는 모드이고,
`TestWithoutNotifications`는 테스트 모드로 실제 차단을 의미하지 않습니다.
`Disable`도 선택할 수 있습니다. 이메일 알림이나 민감한 일치 내용의 보고서는
설정하지 않습니다.

대상은 한 개의 individual agent입니다. 그 대상 내부의 `Inclusions: Tenant / All`은
**그 agent를 사용하는 모든 사용자**를 뜻하며, 모든 앱이나 같은 Blueprint의
다른 agent를 대상으로 확장하지 않습니다.

## 결과와 복구

- 성공 출력은 `ConfigurationReadBack`입니다. 정책 저장/모드 조회 확인을 뜻하며
  배포 완료, runtime 차단, Agent 365/Defender 표시를 증명하지 않습니다.
- 같은 이름의 정책이나 규칙이 이미 있으면 중단합니다. 재실행해도 덮어쓰거나
  기존 대상을 교체하지 않습니다.
- 변경 호출이 실패하거나 readback이 일치하지 않으면 결과를 미확정으로 취급합니다.
  자동 재시도, 삭제, 롤백, 기존 정책 채택은 하지 않습니다. 정책만 생성되었거나
  규칙까지 생긴 비활성 정책이 남을 수 있고, 모드 변경 응답이 유실되면 이미
  활성화되었을 수도 있습니다. 출력한 작업 단계와 정책/규칙 이름으로 먼저 조회합니다.

동일 테넌트의 Security & Compliance PowerShell에 연결한 뒤 읽기 전용으로 확인합니다.
이 명령은 자동 수정이나 재생성을 하지 않습니다.

```powershell
Connect-IPPSSession -UserPrincipalName 'admin@your-tenant.onmicrosoft.com' `
  -AzureADAuthorizationEndpointUri 'https://login.microsoftonline.com/<tenant-guid>'
Get-DlpCompliancePolicy -Identity 'Agent SIT protection' |
  Format-List Guid,Name,Mode,EnforcementPlanes,Locations,DistributionStatus
Get-DlpComplianceRule -Policy 'Agent SIT protection' |
  Format-List Guid,Name,Disabled,ContentContainsSensitiveInformation,RestrictAccess
```

다시 만들기 전에 원래 작업이 완료되었는지 확인합니다. 불완전한 정책의 수정이나
삭제는 정책 소유자가 별도로 검토합니다. 이름만 바꿔 중복 정책을 만드는 식으로
미확정 상태를 회피하지 않습니다.

Gateway에서 사용하려면 정책 생성 후 최신 catalog에서 정책을 선택하고 기존의
개별 agent review/confirm 절차를 거칩니다. 이 스크립트는 Gateway의 assignment
기록이나 runtime 권한을 만들지 않습니다. 이어 일반 입력 allow, 합성 SIT 입력
block, 같은 Blueprint의 다른 agent 범위를 각각 검증합니다. 다른 적용 정책도
결과에 영향을 줄 수 있습니다.

## 로컬 검증 범위

오프라인 회귀 테스트는 모의 응답으로 tenant/identity/SIT 검증, 미리보기,
기존 정책 보존, 불확실한 변경 결과에서 중단하는 동작을 검사합니다.
실제 테넌트의 생성, 정책 배포, allow/block 및 sibling 범위 검증은 별도 live
검사이며, 스크립트를 준비하는 작업에서는 실행하지 않습니다.
