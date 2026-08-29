# Microsoft Purview data-security setup

This runbook configures the optional Microsoft Purview data-security adapter used
by the Gateway API. Purview is independent of Agent 365 observability and the
optional Azure Monitor mirror.

The runtime implementation uses Microsoft Graph v1.0. It does not create or edit
tenant DLP policies. Keep `Purview:Enabled=false` until the tenant policy,
licensing, managed identity, and Graph application permissions below have been
verified. Per-agent and system-default Purview settings are rejected while the
global adapter is disabled.

No step in this runbook is evidence that development or production is configured.
Granting application permissions, changing Purview policies, or sending a live
content canary requires explicit authorization for that tenant and environment.
At the 2026-08-28 development checkpoint, the three documented Graph application
roles are assigned, licensing is user-confirmed, and blueprint-scoped Enforce is
proven. Policy `A365 Tourist OBO Python DLP (OBS Gateway)` targets blueprint
`29fa5cc5-c42b-4bdc-8f99-d85a5b91ad01` with `EnforcementPlanes Application`.
Benign content returns `AuditLogged`; the authorized synthetic credit-card prompt
returns `Blocked`. The live scope is inline for `uploadText` and offline for
`downloadText`.

## Implemented behavior

| Per-agent mode | Gateway behavior |
|---|---|
| Disabled | No content is sent to Purview. |
| `AuditOnly` | Synchronously creates two content activities (`uploadText` for the prompt and `downloadText` for the response). The records contain integrated/protected-app metadata and deterministic content-entry identifiers, but omit prompt/response text and conversation `agents` to match the documented content-activity contract. A Graph failure rejects the interaction with `PURVIEW_DEPENDENCY_UNAVAILABLE`; there is no hidden retry queue. |
| `Enforce` | Computes user protection scopes for the selected reusable blueprint application location, then handles each activity according to its returned mode. `evaluateInline` waits for a `processContent` verdict; `evaluateOffline` still submits to `processContent` and accepts 200/202/204 without requiring a synchronous verdict. Any scope-level or returned `restrictAccess:block` blocks. Missing scope/identity, processing errors, invalid execution mode, or Graph failure fail closed. |

Protection-scope cache entries are keyed by both Entra user object ID and reusable
blueprint client ID so children sharing the blueprint reuse the policy scope. Offline-
only and empty scopes are not cached while policy distribution may be converging.
The response ETag is sent as `If-None-Match` to
`processContent`; a `protectionScopeState=modified` response forces one refresh and
one retry. A second `modified` response fails closed.

The physical `PurviewDecisions.ProtectionScopeId` column is a legacy name. The
implementation stores Graph's `protectionScopeState` there; Graph returns a
collection of `policyUserScope` objects, not a single protection-scope ID.

## Microsoft contracts and prerequisites

The authoritative contracts are:

- [Compute a user's protection scopes](https://learn.microsoft.com/graph/api/userprotectionscopecontainer-compute?view=graph-rest-1.0)
- [Process content](https://learn.microsoft.com/graph/api/userdatasecurityandgovernance-processcontent?view=graph-rest-1.0)
- [Create a content activity](https://learn.microsoft.com/graph/api/activitiescontainer-post-contentactivities?view=graph-rest-1.0)
- [Configure Microsoft Purview for custom apps](https://learn.microsoft.com/purview/developer/configurepurview)
- [Use the Microsoft Purview data-security APIs](https://learn.microsoft.com/purview/developer/use-the-api)
- [Microsoft Graph permissions reference](https://learn.microsoft.com/graph/permissions-reference)

Tenant prerequisites:

1. Confirm the tenant has licensing for the selected Purview/DLP capabilities.
2. Enable the applicable Purview data collection and DLP policies. Collection
   policy controls whether activity records are retained by Purview.
3. Configure policies for the selected reusable blueprint client ID. This is the
   shared governance boundary for all child Agent IDs created under that blueprint;
   it avoids one policy per child. The Gateway API app is the integrated caller,
   while child plus blueprint IDs remain `aiAgentInfo` attribution.
4. For prompt blocking, `uploadText` must resolve to `evaluateInline`. An offline
   `downloadText` scope is valid and is submitted without waiting for a verdict. A
   true response-side inline gate requires both policy support and a phase-specific
   product flow.
5. Use a real Microsoft Entra user object ID in every Purview-enabled interaction.
   The Gateway does not fabricate user context or fall back to the signed-in admin.

Purview policy authoring has two explicit paths. Bootstrap/manual setup remains a
tenant-administrator operation. When the reviewed app-only automation boundary is
enabled, Admin UI registration of a **new** blueprint can instead select an existing
Gateway-managed protection profile or create a new one. Follow the current official configuration guide and
[current `New-DlpComplianceRule` Example 4](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-dlpcompliancerule?#example-4):
the policy location is an individual Entra application, `Location` is the reusable
blueprint client ID, `LocationSource` is `Entra`, and `EnforcementPlanes` contains
`Application` (`Entra` is not the enforcement-plane value). The rule includes the
intended activity-specific `RestrictAccess` actions. A DSPM/KYD collection policy is
separate and does not by itself prove inline blocking.

Use unique nonproduction names and tenant-approved synthetic sensitive information.
The shape below is a review template, not evidence that a policy exists:

```powershell
$blueprintApplicationId = '{Reusable Agent Identity blueprint client ID}'
$locations = @"
[{"Workload":"Applications","Location":"$blueprintApplicationId","LocationDisplayName":"Reusable Agent ID blueprint","LocationSource":"Entra","LocationType":"Individual","Inclusions":[{"Type":"Tenant","Identity":"All"}]}]
"@

New-DlpCompliancePolicy `
  -Name 'A365 Gateway inline DLP test' `
  -Mode Enable `
  -Locations $locations `
  -EnforcementPlanes @('Application')

New-DlpComplianceRule `
  -Name 'A365 Gateway inline DLP test rule' `
  -Policy 'A365 Gateway inline DLP test' `
  -ContentContainsSensitiveInformation @{ Name = '{tenant-approved sensitive information type}' } `
  -RestrictAccess @(
    @{ setting = 'UploadText'; value = 'Block' }
  )
```

### Automated protection-profile boundary

The worker uses `Connect-IPPSSession` with an application ID and an X.509
certificate object. The automation application requires `Exchange.ManageAsApp` for
Security & Compliance PowerShell plus the narrow Purview compliance RBAC needed for
`Get/New/Set-FeatureConfiguration`, `Get/New/Set-DlpCompliancePolicy`, and
`Get/New-DlpComplianceRule`. Do not assign these permissions to the external agent,
child Agent ID, blueprint, Gateway API identity, or ordinary signed-in user.

Only Gateway-managed profiles stored in `PurviewPolicyProfiles` are reusable in the
portal. On every assignment the worker performs a read-modify-write: it preserves
all existing application locations, adds the exact blueprint client/application
ID, and then exactly reads back both the collection and DLP policy. A missing or
ambiguous readback fails the `ResolveBlueprint` step before child creation. The
worker never removes an application location in this flow.

The automation certificate is a base64 PKCS#12 stored as a Key Vault secret. It is
loaded with `DefaultAzureCredential`, re-exported with a random process-only
password, passed to PowerShell through a short-lived private file, and deleted in a
`finally` block. Never place its value or password in Container Apps environment
variables, command-line arguments, logs, docs, SQL, or chat.

Development evidence: a separate attempt to create a new DSPM collection policy for
the Gateway app was rejected with `InvalidAzureBillingSubscriptionException` because
the linked Azure billing subscription then reported `SkuName=Free`. On 2026-08-28
the user reported that the accidentally deleted Azure PAYG resource was recreated
and the policy now shows synchronization in progress. Microsoft documents that PAYG
enablement can take a few hours. Treat this as pending external propagation until the
billing association is Active, policy synchronization completes, and new collection
evidence lands. This does not negate the already proven blueprint-scoped inline DLP
decision path, but collection-policy recovery must not yet be reported as complete.

## Managed identity and least-privilege Graph roles

The Gateway API process makes all three calls. Grant these application roles to the
managed identity actually used by the Gateway API:

| Runtime call | Least-privilege application role | Microsoft Graph app-role ID |
|---|---|---|
| `/users/{id}/.../protectionScopes/compute` | `ProtectionScopes.Compute.User` | `fe696d63-5e1f-4515-8232-cccc316903c6` |
| `/users/{id}/.../processContent` | `Content.Process.User` | `24ceb246-ad29-4680-90b4-3e91ffad15eb` |
| `/users/{id}/.../activities/contentActivities` | `ContentActivity.Write` | `2932e07a-3c29-44e4-bb36-6d0fc176387f` |

All require administrator consent. Do not grant the historical/nonexistent
`DataSecurityAndGovernance.Scoping.Read.All` or
`DataSecurityAndGovernance.Content.Process.All` names. Do not grant these roles to
the provisioning worker unless it separately begins making Purview calls.

When `Purview:ManagedIdentityClientId` is blank, the adapter uses the Gateway API's
system-assigned managed identity. When it contains a client ID, it uses that
user-assigned managed identity. The value is a client ID, not an object/principal
ID. Never configure a client secret for this adapter.

### Read-only role verification

After an authorized administrator grants consent, compare the Gateway API managed
identity's Microsoft Graph app-role assignments with the three IDs above. One
read-only Microsoft Graph PowerShell approach is:

```powershell
Connect-MgGraph -Scopes "Application.Read.All"

$gatewayPrincipalId = "{gatewayApiManagedIdentityPrincipalId}"
$graphAppId = "00000003-0000-0000-c000-000000000000"
$graph = Get-MgServicePrincipal -Filter "appId eq '$graphAppId'"

Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $gatewayPrincipalId |
    Where-Object ResourceId -eq $graph.Id |
    Select-Object AppRoleId, ResourceDisplayName
```

This check does not grant or revoke anything. Do not print tokens, assertions, or
environment secrets while verifying the assignment.

## Gateway configuration

Configuration keys and environment-variable equivalents:

```json
{
  "Purview": {
    "Enabled": false,
    "DefaultMode": "AuditOnly",
    "ProtectionScopeCacheMinutes": 30,
    "RequestTimeoutSeconds": 15,
    "AppName": "A365 Gateway",
    "AppVersion": "1.0",
    "ManagedIdentityClientId": "",
    "PolicyProvisioningEnabled": false,
    "PolicyProvisioningOrganization": "",
    "PolicyProvisioningApplicationId": "",
    "PolicyProvisioningCertificateSecretUri": "",
    "PolicyProvisioningPowerShellPath": "pwsh",
    "PolicyProvisioningTimeoutSeconds": 180,
    "DefaultSensitiveInformationType": "Credit Card Number"
  }
}
```

| JSON key | Container Apps environment variable | Constraint |
|---|---|---|
| `Enabled` | `Purview__Enabled` | Set to `true` only after all prerequisites and a controlled canary pass. |
| `DefaultMode` | `Purview__DefaultMode` | `AuditOnly` or `Enforce`. This is adapter configuration; the persisted system default remains separately managed through the admin API. |
| `ProtectionScopeCacheMinutes` | `Purview__ProtectionScopeCacheMinutes` | 1–1440; default 30. |
| `RequestTimeoutSeconds` | `Purview__RequestTimeoutSeconds` | 1–120; default 15. |
| `AppName` | `Purview__AppName` | Nonempty, maximum 256 characters. Sent as integrated-app metadata. |
| `AppVersion` | `Purview__AppVersion` | Nonempty, maximum 64 characters. |
| `ManagedIdentityClientId` | `Purview__ManagedIdentityClientId` | Optional nonempty GUID for a user-assigned managed identity. |
| `PolicyProvisioningEnabled` | `Purview__PolicyProvisioningEnabled` | Default false. Enables only the worker's reviewed protection-profile automation. |
| `PolicyProvisioningOrganization` | `Purview__PolicyProvisioningOrganization` | Microsoft 365 organization domain used by app-only `Connect-IPPSSession`. |
| `PolicyProvisioningApplicationId` | `Purview__PolicyProvisioningApplicationId` | Certificate-authenticated automation app client ID; not a secret. |
| `PolicyProvisioningCertificateSecretUri` | `Purview__PolicyProvisioningCertificateSecretUri` | HTTPS Key Vault secret URI for the base64 PKCS#12. Never document its value. |
| `PolicyProvisioningPowerShellPath` | `Purview__PolicyProvisioningPowerShellPath` | Defaults to `pwsh`; worker image pins ExchangeOnlineManagement 3.10.1. |
| `PolicyProvisioningTimeoutSeconds` | `Purview__PolicyProvisioningTimeoutSeconds` | 30–900; default 180. |
| `DefaultSensitiveInformationType` | `Purview__DefaultSensitiveInformationType` | Tenant-approved SIT used by the reviewed default rule template. |

The clean-subscription bootstrap exposes these settings as
`purview.policyProvisioningEnabled`, `policyProvisioningOrganization`,
`policyProvisioningApplicationId`, and
`policyProvisioningCertificateSecretUri`. The URI must be versionless and point to
the Gateway shared Key Vault. Bootstrap grants the worker only **Key Vault Secrets
User** when automation is enabled; it does not create or privilege the Microsoft 365
automation application. This keeps tenant-wide Security & Compliance authority an
explicit administrator prerequisite rather than an implicit Azure deployment side
effect.

Configuration is validated at API startup. `Enabled=false` is the safe deployment
default. Enabling a registration or the system Purview default while it is false
returns `UNSUPPORTED_FEATURE_CONFIGURATION` before any database mutation.

## Verification order

Use synthetic content and a nonproduction test user. Do not use real customer,
employee, credential, financial, or health data.

1. Verify the managed identity and three app-role assignments read-only.
2. Verify the Purview policy targets the reusable blueprint client ID with
   `EnforcementPlanes Application`. Verify each activity's intended mode; the child
   Agent ID is attribution metadata, not the protected policy location.
3. Start the API with `Purview:Enabled=true` only in the authorized environment.
4. Register or update one development agent to `AuditOnly`. Submit one interaction
   and confirm a `PurviewDecision` of `AuditLogged`; confirm both Graph calls return
   HTTP 201 and Purview receives metadata without raw content.
5. Change that agent to `Enforce`. Submit a benign synthetic interaction and confirm
   an allowed receipt and a stored `protectionScopeState`.
6. Submit a tenant-approved synthetic DLP trigger. Confirm an exact
   `restrictAccess:block` result yields an interaction receipt whose processing
   status is `Failed` and Purview status is `Blocked`.
7. Remove or deny access only in a disposable test setup, if authorized, and confirm
   the request returns RFC 9457 problem details with HTTP 503 and
   `PURVIEW_DEPENDENCY_UNAVAILABLE`, without persisting the interaction content.

Never infer policy coverage from an empty `policyActions` array alone. Verify the
computed scope includes the intended activity and mode, and run an authorized
synthetic block canary.

## Current product boundary

`POST /api/v1/ai-interactions` receives a completed prompt/response pair. In
`Enforce` mode it handles each returned activity mode before the Gateway persists or
exports the completed pair and marks a blocked receipt as failed, but it cannot undo
model execution that already occurred in the external runtime. A true pre-model prompt gate requires a separate
phase-specific evaluation API and an external runtime that calls it before model
invocation. The old OpenAPI text for `/ai-interactions:evaluate` is not evidence of
an implemented route. Do not claim pre-execution enforcement until that route and
its idempotent persistence contract are implemented and tested.

Microsoft Graph does not document an idempotency key for creating a content
activity. The Gateway's SQL idempotency lock prevents concurrent duplicate calls and
the content-entry identifiers are stable across retries, but a process crash after
Graph accepts an activity and before the local transaction commits can still yield
an at-least-once duplicate in the external audit store. Treat exact-once Purview
audit delivery as an unimplemented production property; reconcile by the stable
identifier/correlation evidence if the tenant requires it.

## Troubleshooting

| Symptom | Safe interpretation and next check |
|---|---|
| `UNSUPPORTED_FEATURE_CONFIGURATION` | Global `Purview:Enabled` is false. Verify prerequisites before enabling it. |
| HTTP 503 `PURVIEW_DEPENDENCY_UNAVAILABLE` | No trusted decision was obtained. Check managed identity selection, role assignments, tenant policy, Graph availability, and user/child/blueprint IDs. The response intentionally omits Graph body details. No local content is persisted, although a preceding external audit call might already have succeeded. |
| `PURVIEW_SCOPE_INVALID_EXECUTION_MODE` in internal diagnostics | Graph returned a mode other than the documented `evaluateInline` or `evaluateOffline`; the Gateway fails closed. |
| `PURVIEW_INLINE_DECISION_MISSING` | Graph returned 202/204 for an inline policy. The Gateway correctly failed closed. |
| `PURVIEW_SCOPE_UNSTABLE` | Scope state changed twice during one evaluation. Retry under the endpoint's idempotency rules after policy propagation stabilizes. |
| No applicable scope | For `Enforce`, treat this as a policy/configuration gap; for `AuditOnly`, content activities can still be recorded. |

Logs contain registration and correlation IDs only. They must never contain prompt
or response text, access tokens, Graph response bodies, or clear Gateway keys.
