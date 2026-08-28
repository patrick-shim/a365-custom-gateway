# Agent 365 Observability Setup Runbook

The Gateway exports sanitized activity telemetry as the provisioned **Agent
Identity**, not as one shared worker/exporter identity. Azure Monitor mirroring is
a separate optional destination, and Microsoft Purview policy evaluation remains
independent of both observability destinations.

Current checkpoint (2026-08-28): development intentionally runs continuous
registration, automatic delegated completion for a signed-in Gateway Administrator,
worker provisioning, and data-plane relay. Two registrations are Active: one created
a new reusable blueprint and one selected an existing reusable blueprint. Both are
Available A365CustomGateway agents in Microsoft 365 Admin Center. The v3 queue is
`0/0/9`; retained v2 is `0/0/3`, and historical v1 is `0/0/2`.

Live clients proved registration-bound ingress, matched activity/interaction HTTP
202, child token exchange, and sanitized Agent 365 OTLP HTTP 200. Blueprint-scoped
Purview Enforce separately proved a benign `AuditLogged` receipt and a synthetic
sensitive prompt blocked before observability enqueue. The older
`live-state-20260828-v3-success-final.json` SQL artifact predates the two continuous
canaries; retain it as recovery/history evidence, not current job/outbox evidence.
Exact current IDs, revisions, and evidence boundaries are in
[`development-deployment-status.md`](development-deployment-status.md).

The historical v2 canary that stopped at 71% remains unresolved and must not be
retried, attached to v3, or cleaned up. It created child Agent ID
`8e4859bd-477c-4133-adb1-9030ec13bf5c` and assigned OtelWrite, but its app-only
Registry POST returned HTTP 500 without a durable Registry ID. Portal searches are
not API proof of the outcome. Preserve that registration, child, role assignment,
FIC, message, and credential boundary. Reconcile that exact historical request only
through read-only Registry/Admin Center evidence. Workflow v3 does not depend on it.

## Identity model

For each workflow-v3 registration:

1. The reusable Agent Identity Blueprint has one deterministic federated credential
   for the Gateway provisioning/egress worker managed identity. Reused blueprints do
   not receive one FIC per registration.
2. The child Agent ID receives `Agent365.Observability.OtelWrite` on Microsoft resource
   application `9b975845-388f-4429-889e-eab1ef63949c`.
3. The worker proves the official flow: managed-identity assertion to
   Blueprint T1 token using `fmi_path=<agent-identity-client-id>`, then an Agent
   Identity token for the target resource.
4. The worker stops after role assignment with the operation at 71% and asks a
   signed-in Gateway administrator to complete the Registry create through the API's
   delegated OBO endpoint. An accepted HTTP 201 create advances the operation to 85% and emits
   only the final-stage continuation.
5. Final worker verification re-reads the resource relationships, validates the
   Agent 365 observability token, and uses the API-persisted delegated Registry
   evidence. It performs no Registry HTTP request and does not assign a child Gateway
   role or call a Gateway readiness endpoint.
6. The external client submits to the Gateway with its one-time-issued,
   per-registration Gateway API key. It needs no Entra credential or managed-
   identity object ID for normal ingress.

The former `Agent365__ObservabilityExporterClientId` and
`Agent365__ObservabilityManagedIdentityClientId` settings are retired. Do not grant
`Agent365.Observability.OtelWrite` to the worker. The retained
`tools/configure-agent365-observability.ps1` entry point intentionally fails without
making Azure changes so an operator cannot accidentally restore the shared-exporter
model.

## Prerequisites

| Requirement | Details |
|---|---|
| Worker identity | The provisioning Worker has an Azure managed identity and can request `api://AzureADTokenExchange/.default`. |
| Blueprint credential permission | The Worker has consent for `AgentIdentityBlueprint.AddRemoveCreds.All`. |
| Assignment permission | The Worker has consent for `Application.Read.All` and `AppRoleAssignment.ReadWrite.All`. |
| Agent 365 resource | The tenant exposes one enabled application role named `Agent365.Observability.OtelWrite` for application members. |
| Per-agent mapping | The Gateway record contains the child Agent Identity client ID and Blueprint client ID. |
| Blueprint compatibility | The selected typed blueprint contains every reviewed Agent 365 provider entry configured in `managerApplications`. A typed blueprint with an empty or mismatched collection is not sufficient. |
| Human attribution | Agent 365-bound events contain a real tenant user object ID where the current schema requires it. |

Blueprint Graph `id` and blueprint `appId` are separate named fields whose values may
be the same GUID; read-only development inventory has observed equal pairs, while
the last independently captured catalog contained 12 entries. A later create-new
flow was reported successful, so recapture before relying on that count. The Gateway retains both properties and
uses the route-specific field without inferring it from value equality. Microsoft
currently documents the child Agent Identity object ID and app/client ID as the same GUID and the Gateway
validates that child equality. Do not replace any of these with a blueprint-
principal, Registry, or Gateway-owned registration ID.

The read-only provisioning preflight checks that the Agent 365 resource publishes
the expected role. It does not grant that role to the Worker. Workflow v3 assigns
the role to each child Agent Identity and verifies the resulting token.

## Required Worker configuration

| Environment variable | Required value |
|---|---|
| `Agent365__TenantId` | Microsoft Entra tenant UUID. |
| `Agent365__ObservabilityServerAddress` | Gateway API hostname used for sanitized `server.address`, without scheme or path. |
| `Agent365__ObservabilityServerPort` | Defaults to `443`. |
| `Agent365__ProvisioningManagedIdentityClientId` | Optional; set only when selecting a user-assigned managed identity. Omit for the Worker's system-assigned identity. |
| `Agent365__ProvisioningManagedIdentityPrincipalId` | Required trusted service-principal object ID of the worker identity; workflow v3 verifies the token caller `oid` against it before configuring federation. |

At export time all three of these values must equal the child Agent Identity client
ID:

- the final token's `appid` or `azp` claim;
- `{agentId}` in
  `/observabilityService/tenants/{tenantId}/otlp/agents/{agentId}/traces`;
- the `gen_ai.agent.id` telemetry attribute.

`microsoft.a365.agent.blueprint.id` must contain the actual Blueprint client ID.
The exporter fails closed if either per-agent identifier is missing. For an Entra
child Agent Identity, the current exporter intentionally omits
`gen_ai.agent.type` and `microsoft.a365.agent.platform.id`; those attributes would
misidentify the child in this contract. Preserve `gen_ai.agent.id` as the child
Agent Identity client ID and `microsoft.a365.agent.blueprint.id` as the blueprint
client ID.

## Default destinations

Changing a seed value does not update the existing singleton configuration. To make
Agent 365 the default for new registrations while keeping the Azure Monitor mirror
optional, update the live setting with an administrator token:

```powershell
$headers = @{
  Authorization = "Bearer {gatewayAdministratorToken}"
  'Content-Type' = 'application/json'
  'Idempotency-Key' = [guid]::NewGuid().ToString('D')
}

$body = @{
  defaultAgent365ObservabilityEnabled = $true
  defaultAzureMonitorExportEnabled = $false
} | ConvertTo-Json

Invoke-RestMethod `
  -Method Patch `
  -Uri 'https://{gatewayHost}/api/v1/system/config' `
  -Headers $headers `
  -Body $body
```

Confirm `GET /api/v1/system/config` returns Agent 365 enabled and Azure Monitor
disabled. This affects new registrations only. Existing records keep their stored
destinations until `PATCH /api/v1/agents/{agentId}/features` changes them.

Each accepted event snapshots its destinations in the outbox message. A later
feature change does not retroactively add or remove a destination. When both are
enabled, Azure Monitor mirror claiming remains independent of Agent 365 retries.

## Current actor-attribution boundary

The current contract supports Agent 365 export only for human-attributed activity:
use `actor.type: User` and the real Microsoft Entra object ID in
`actor.tenantUserObjectId`. The API rejects `Agent` and `System` actors before
persistence when Agent 365 is a destination. Those actor types remain valid when
only Azure Monitor or no activity destination is enabled.

Do not substitute an email address or label an agent as `User`. Agent-to-agent
observability needs additional caller-agent attributes that are not yet represented
by the Gateway request contract. See Microsoft's
[observability attribute reference](https://learn.microsoft.com/en-us/microsoft-agent-365/developer/observability-attribute-reference).

## Validation and troubleshooting

The order is **prepare -> bounded canary -> deactivate -> finalize**. After the four
pre-cutover SQL deltas, separate recovery evidence, inert N:N deployment, exact
consent/configuration, an isolated empty v3 queue, and empty outbox are verified,
For an explicitly authorized exact-bound staging proof, register exactly one fresh
canary through workflow v3. The worker must pause at 71%; a signed-in Gateway
administrator must complete the OBO Registry action,
which advances the operation to 85%; the final worker stage must then report the
registration `Active`. Capture the one-time Gateway key without logging it and use
the bounded helper below to prove registration binding and accepted ingress. Return
admission, API Registry completion, and the worker inert and prove old API revisions
receive zero traffic before running scoped-idempotency finalization. Never finalize
after a failed or inconclusive canary.

### Bounded data-plane proof

Use `tools/invoke-gateway-data-plane-canary.ps1`; do not hand-build a command that
places the Gateway key in an argument, environment variable, history, transcript, or
file. The helper reads the one-time key from the Windows clipboard, clears the
clipboard immediately, retains the key only in process memory, waits for an explicit
newline, and never prints a key, request body, or response body.

For an already-Active registration, pass `-NoWait` to send immediately. Omit it
during provisioning so the process captures the key and waits for the Active state.

1. In the Admin UI, copy **only** the fresh canary registration's one-time Gateway
   API key field. Do not copy the surrounding page or record it elsewhere.
2. From PowerShell 7 in the repository root, start the helper with public identifiers
   only. Do not enable `Start-Transcript`, shell tracing, or output redirection:

   ```powershell
   pwsh ./tools/invoke-gateway-data-plane-canary.ps1 `
     -ApiBaseUrl 'https://{gateway-api-host}/' `
     -ExternalAgentId '{fresh-v3-external-agent-id}' `
     -TenantUserObjectId '{real-tenant-user-object-id}'
   ```

3. Confirm the helper reports `[READY]` and that the clipboard is cleared. Leave the
   process waiting. Do not press Enter until the provisioning operation reports
   `Active` after the 85% delegated Registry boundary and final verification.
4. Press Enter once. The helper sends exactly three requests with distinct
   idempotency keys: a deliberately mismatched activity that must return HTTP 403, a
   registration-matched activity that must return HTTP 202, and a matched interaction
   that must return HTTP 202. It prints only those statuses and safe correlation IDs.
5. Treat any other status as a failed/inconclusive canary. Close all creation and
   worker gates, retain the safe correlations for diagnosis, and do not expose a
   dependency body or reuse the key in an ad hoc command. On success, separately
   verify Agent 365 downstream landing before claiming end-to-end observability.

`OpenAdmission` is both time-bounded and exact-bound. The controller accepts a
30--300 second operator window that starts only after the new API revision is ready,
a 60--300 second rollout allowance, and a hard combined exposure ceiling of 600
seconds. It also configures only the reviewed generated external ID; the API rejects
every other registration and keeps retry unbound. The API-enforced expiry remains
the crash boundary, and the controller closes admission in `finally`.

None of the three retained workflow-v2 canaries is this proof. The first stopped GET-only at
`ResolveBlueprint` with `AGENT365_PLATFORM_ACCEPTANCE_UNCONFIGURED`; it made no
Microsoft mutation. The second selected compatible `simple-echo-agent Blueprint`,
made exactly one FIC POST that returned HTTP 201, then failed closed when the
immediate list read was stale. Later read-only reconciliation proved exactly one
matching reusable FIC. It created no child Agent ID, Agent 365 role, Registry record,
or telemetry mapping. The third GET-reused that FIC, created child
`8e4859bd-477c-4133-adb1-9030ec13bf5c`, and assigned OtelWrite, then failed
outcome-unknown at Registry HTTP 500. Portal searches after MFA found neither its
exact display name nor child ID among 341 agents, but that is not API proof that the
backend create had no effect. Preserve all registrations, three v2 DLQ messages,
the FIC, child, and role assignment; never retry its Registry POST, move its message,
or attach it to the fresh workflow-v3 canary.

An Agent 365 OTLP HTTP 200 response with no rejected spans proves only that the
service accepted that request. It does not prove downstream ingestion or search
availability. Completion evidence must separately find the controlled event in
Microsoft Defender `CloudAppEvents` after allowing for service delay and confirming
the tenant's Agent 365/Microsoft 365 licensing. Until that read succeeds, record
telemetry as accepted but landing unverified.

| Symptom | Check |
|---|---|
| `InvalidAgentIdentityClientId` or `InvalidBlueprintClientId` | The Gateway record contains the child Agent Identity ID (object/client GUID) and the persisted value from the Blueprint `appId` field, not a Gateway registration UUID. The Blueprint `id` may have the same value, but route semantics still come from the named field. |
| `AGENT365_PLATFORM_ACCEPTANCE_UNCONFIGURED` or `AGENT_IDENTITY_BLUEPRINT_INCOMPATIBLE` | The selected blueprint does not contain every configured Agent 365 manager application, or the API has no reviewed manager configuration. Choose an enabled compatible catalog row after configuration/deployment is verified; never retry the failed registration. |
| `ManagedIdentityCredentialUnavailable` | The Worker has the intended Azure managed identity and can reach the identity endpoint. |
| `BlueprintTokenHttp401/403` | The Blueprint has the correct federated credential for the calling managed-identity object ID and audience `api://AzureADTokenExchange`. |
| `MissingOtelWriteRole` or Agent 365 HTTP 403 | `Agent365.Observability.OtelWrite` is assigned to the child Agent Identity, not the Worker. Allow for Entra propagation before retry. |
| `AgentIdentityMismatch` or `InvalidAudience` | The token `appid`/`azp`, OTLP URL agent segment, and `gen_ai.agent.id` all identify the same child Agent Identity. |
| Agent 365 returns HTTP 200 but no event appears in Defender | HTTP 200 is request acceptance only. Allow for service delay, verify licensing, then query `CloudAppEvents` using the controlled correlation and safe agent identifiers; do not claim landing from the exporter response alone. |
| `MissingServerAddress` | `Agent365__ObservabilityServerAddress` contains the Gateway API hostname. |
| Validation failure on actor/user context | Supply a real tenant user object ID for the human caller when Agent 365 export is enabled. |
| Gateway ingress `401` | Verify the presented key is the current unexpired, unrevoked key for this registration; issue a replacement because clear keys cannot be recovered. |
| Gateway ingress `403 AGENT_IDENTITY_MISMATCH` | The body `externalAgentId` does not match the registration selected by the key. Never bypass the binding with a global key. |

Never log bearer tokens, managed-identity assertions, prompts, responses, or
dependency response bodies. Official references: [autonomous Agent Identity
authentication](https://learn.microsoft.com/en-us/entra/agent-id/autonomous-agent-authentication-authorization-flow)
and [Agent 365 observability authentication](https://learn.microsoft.com/en-us/microsoft-agent-365/developer/observability-authentication-setup).
