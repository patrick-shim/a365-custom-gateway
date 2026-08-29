# Credential and federation lifecycle runbook

This runbook covers the credentials and identity relationships that actually exist
in the A365 Gateway. Read `../../AGENTS.md`, `../../CLAUDE.md`,
[`../implementation-status.md`](../implementation-status.md), and
[`../agent-guides/provisioning.md`](../agent-guides/provisioning.md) before acting.

Last reconciled with the working tree and development deployment: **2026-08-28**.

## Current boundary

- Workflow v3 does **not** create one ordinary Entra app registration, client secret,
  or certificate per external agent.
- Each external registration receives a unique Gateway-issued API key. The clear key
  is returned exactly once; only its ID, salt, hash, timestamps, and registration
  ownership are stored. Normal Gateway ingress needs no external managed identity or
  Entra credential.
- A reusable blueprint has one deterministic FIC for the Gateway worker managed
  identity. The worker uses `fmi_path=<child-agent-id>` for outbound Agent 365 tokens.
  Managed-identity token material is issued by Azure; the Gateway stores only safe
  object/client/FIC identifiers and never an assertion or token.
- The child Agent Identity has no client secret, certificate, or FIC of its own.
- The Gateway API completes Registry through delegated OBO using one exact
  managed-identity federated credential on the API application; it does not use a
  client secret or certificate. The FIC has the tenant-v2 issuer, API managed-
  identity principal/object ID subject, and sole `api://AzureADTokenExchange`
  audience.
- `AgentCredentialReference` and the dedicated provisioning vault are compatibility/
  bootstrap artifacts for workflow v3. The deployed dedicated vault is empty and is
  not proof of runtime credential readiness.
- Credential lifecycle uses only `GET`/`POST /api/v1/agents/{agentId}/credentials`
  and `DELETE /api/v1/agents/{agentId}/credentials/{credentialId}`. Never invent a
  webhook or `credentials:rotate` route.

Workflow v3 development continuous mode has two Active registrations covering
create-new and reuse-existing blueprint paths. Their currently safe active key IDs
are `b3abe5d0-7181-45aa-beb5-2dddba328f08` and
`ac74e01b-a7ec-4cb6-93d7-59c0cdfb7fbb`; never recover, expose, or document a clear
key. Bound Gateway ingress returned HTTP 202, Agent 365 OTLP accepted sanitized
exports, and blueprint-scoped Purview Enforce produced both benign-audit and
synthetic-block proof.

Final verification proved API revision
`ca-gateway-api-dev--purviewguard-20260828222324`, worker revision
`ca-gateway-worker-dev-vnet--rbacrefresh-202608282058`, and v3 queue `0/0/10`.
Two exact-operation completion windows closed without user action. Three bounded
workflow-v2 failures and their v2 DLQ messages are retained. The first
failed GET-only at
`ResolveBlueprint` without a Microsoft mutation. The second made exactly one FIC
POST, then failed closed on delayed visibility; later GET-only reconciliation proved
one matching reusable FIC. Neither created a child Agent ID, Agent 365 role, Registry
record, or telemetry mapping. The third reused that FIC, created a child, assigned
OtelWrite, then received Registry HTTP 500 without a durable ID; its outcome is
unknown and no live child-token or ingress canary has passed.
The clear keys were not recorded in deployment evidence and must not be recovered or
reused. Preserve all failed historical registrations/messages, both historical-v1
messages, the reconciled FIC, child, and role. Never retry or attach an unknown POST
outcome. Final zero-script evidence is
`artifacts/deployment-evidence/live-state-20260828-v3-success-final.json`. The next
credential action is ordinary administrator lifecycle work against the Active
registration; it does not authorize replaying a historical operation. This does not
grant production privilege, historical-worker
cutover, DLQ disposition, destructive credential changes, or SQL finalization before
successful canary recovery.

## Non-disclosure rule

Agents must not generate, receive, print, paste, copy, or pass a plaintext secret or
password through a command line, shell variable, patch, chat, log, or tracked file.
Do not rely on clearing shell history after exposure. Any separately authorized
human-run credential operation must use an approved non-echoing vault-integrated
procedure and record only safe metadata such as object ID, key ID, expiry, vault
reference, actor, and correlation/change record.

`.secrets` is authorized private runtime input only. Deployment tooling may consume
required values through the existing non-echoing path; humans and agents must never
render, print, log, document, copy, alter, normalize, or commit its values.

## Credential inventory

| Relationship | Current mechanism | Rotation/lifecycle owner |
|---|---|---|
| Gateway API -> Azure SQL, Service Bus, Key Vault | System-assigned managed identity | Azure rotates tokens; re-establish RBAC/contained-user access if the identity is recreated |
| Provisioning worker -> Azure SQL, Service Bus, Graph | System-assigned managed identity | Azure rotates tokens; Graph/admin consent and deferred Service Bus roles are separate explicit grants |
| External agent -> Gateway | Unique per-registration Gateway API key; only salted verifier is stored | Gateway administrator issues a replacement, deploys/verifies it, then revokes the named old key |
| Gateway worker -> Agent Identity Blueprint | One deterministic worker managed-identity FIC per reusable blueprint | Azure rotates tokens; worker identity recreation requires an explicit FIC and configuration lifecycle operation |
| Gateway API -> Entra OBO confidential client | One exact managed-identity FIC on the Gateway API application; no client secret | API identity recreation requires reviewed replacement of the FIC subject plus independent delegated-consent/FIC readback before traffic |
| Blueprint -> child Agent ID token | Agent ID exchange using `fmi_path` | Microsoft identity platform; verify Agent 365 audience, child `appid`/`azp`, and observability role without logging tokens |
| Admin UI -> Gateway API | Microsoft Identity Web delegated downstream token | Entra token lifecycle; confidential-client material, if configured, is handled only through an approved non-echoing operator procedure |
| GitHub Actions -> Azure | Workload identity federation | No shared deployment secret; maintain issuer/subject/audience and Azure RBAC |
| SQL administrative access | Break-glass/operator credential or Entra administrator | Not used by the running Gateway; privileged human procedure only |

## Managed-identity recreation

Recreating a system-assigned identity changes its service-principal object ID and
invalidates role assignments tied to the old principal. Treat recreation as a
controlled identity replacement, not a routine rotation.

1. Keep API registration/retry admission false and the affected worker's processing,
   outbox relay, provisioning, and Registry execution gates off. The deployed API
   outbox relay is a separate shared publisher and is not described as disabled by
   this identity-maintenance boundary.
2. Record the old resource and principal IDs without accessing any token.
3. Recreate the identity only with explicit authorization for the affected Azure or
   Entra resource.
4. Re-establish only the documented Azure RBAC, SQL contained-user, and Graph
   application roles for the new principal. Tenant admin consent is a separate
   privileged action and is not implied by this runbook.
5. Re-run the read-only prerequisite preflight and dependency health checks.
6. For the provisioning worker, deploy/verify the intended workflow version inert
   before considering activation.
7. Reconcile every blueprint FIC by deterministic name and safe identifier. A FIC
   bound to the previous worker principal cannot authorize the replacement
   principal. Do not delete or replace one ad hoc: Microsoft-resource deletion is
   unsupported, and any new trust mutation needs an explicit reviewed operation.
8. For a Gateway API identity replacement, use the reviewed workflow-v3 Entra helper
   to plan/apply the exact API-app FIC subject change only after ownership/collision
   review; then independently read back issuer, new subject, sole audience, requested
   delegated scopes, and tenant-wide consent. Never add a client-secret fallback.
9. Record the old/new principal IDs, assignments, preflight evidence, and recovery
   state in the development deployment checkpoint.

Never disable or replace the historical worker merely because a new identity exists;
that requires the separate cutover authorization in the shared provisioning guide.

## Per-registration Gateway API-key rotation

These routes are `Gateway.Administrator` control-plane operations. Non-admin UI users
must neither load nor render credential metadata.

1. `GET /api/v1/agents/{agentId}/credentials` lists only key ID, creation, expiry,
   and revocation timestamps. It never returns a key, salt, or hash.
2. `POST /api/v1/agents/{agentId}/credentials` creates a replacement and returns the
   clear `apiKey` exactly once with `Cache-Control: no-store` and `Pragma: no-cache`.
   Hand it to the external operator through the approved secure channel; dismissing
   the UI loses it permanently.
3. Deploy the replacement to the external agent and prove a request resolves the
   intended registration and matching `externalAgentId`.
4. `DELETE /api/v1/agents/{agentId}/credentials/{credentialId}` revokes only that
   named key. Revocation is idempotent. A key owned by another agent returns
   `404 AGENT_INGRESS_CREDENTIAL_NOT_FOUND`.
5. The Gateway returns `409 AGENT_INGRESS_CREDENTIAL_LAST_USABLE` rather than revoke
   the last unexpired, unrevoked key. Issue, deploy, and verify a replacement first.

Issuance/revocation and their safe `GatewayCredentialIssued` or
`GatewayCredentialRevoked` audit event commit together. Audit contains only key ID
and timestamps. Never put a clear key, salt, hash, or token in audit, logs, URLs,
messages, documentation, or idempotency storage.

## Admin UI confidential-client material

The Admin UI uses interactive Entra sign-in and delegated downstream tokens. A local
or deployed confidential-client credential may be required by Microsoft Identity Web,
but it is not an external-agent credential.

- Inspect only the existence/version/reference of the configured value, never its
  plaintext.
- A human Application Administrator rotates it using an approved Entra/Key Vault
  procedure with an overlap window and non-echoing input.
- Update the local user-secret or Container App Key Vault reference without placing
  the value in source, parameters, output, or shell history.
- Verify sign-in, delegated API token acquisition, `/health`, and a read-only API
  route before retiring the old credential.
- Record the Entra key ID, expiry, vault secret version/reference, deployed revision,
  and verification result—not the credential value.

Agents may document or verify the reference wiring but must stop before handling the
plaintext.

## SQL administrative credential

The running API and worker use Entra/managed identity, not a SQL password. A SQL
administrator credential is break-glass/operator material only.

- Rotation requires explicit privileged human authorization and a non-echoing secret
  delivery path.
- Do not pass the password with `az ... --admin-password`, a command-line argument,
  environment variable, or shell variable from an agent session.
- Verify managed-identity database access and the contained users after the human
  rotation. Application revisions should not need a password update.
- The additive N:N upgrade must be rehearsed on a disposable copy and applied
  from a private-DNS-aware runner as described in
  [`upgrade-strategy.md`](upgrade-strategy.md).

## Service Bus, Key Vault, and workload federation

- Current source isolates workflow v3 on `gateway-provisioning-v3`; retained v2
  remains on `gateway-provisioning-v2` and historical v1 on
  `gateway-provisioning`. Verify effective queue-specific RBAC before a trust change
  and never attach generations to another queue. Do not grant
  missing Service Bus/shared-processing roles through a rotation task.
- Service Bus uses managed identity; any connection string in application
  configuration is a defect to investigate without printing it.
- The dedicated provisioning vault currently carries a bootstrap Secrets Officer
  assignment but workflow v3 stores no per-agent secret or certificate there. Do not
  add Certificates Officer or secret material without a separately supported flow.
- GitHub deployment uses workload identity federation. Review issuer, subject,
  audience, repository/environment protection, and Azure RBAC when its trust changes;
  there is no shared secret to rotate.

## Audit evidence

For an authorized lifecycle operation, retain only:

- change/incident identifier, actor, time, environment, and explicit authorization;
- old/new resource and principal IDs, FIC/key IDs, expiry, and vault references where
  applicable;
- Azure Activity Log, Entra audit, Key Vault diagnostic, and deployment revision
  references;
- preflight, health, role-assignment, token-canary, and recovery results with all
  sensitive values excluded.

Do not claim a generic `CredentialRotated` event. The current development API emits
the named safe issue/revoke events above; verify the effective revision before using
those events as incident evidence.

## Completion checklist

- [ ] Correct current/deployed workflow and identity were identified
- [ ] Execution gates remained fail closed during the change
- [ ] Exact authorization and least-privilege roles were recorded
- [ ] No plaintext credential, assertion, or token entered agent-visible input/output
- [ ] Old/new safe IDs and references were recorded
- [ ] SQL/RBAC/Graph/Gateway-FIC relationships were independently verified as applicable
- [ ] Replacement Gateway key was deployed and proved against its bound registration before revocation
- [ ] Old credential/trust was retired only after verified overlap and operator approval
- [ ] `docs/implementation-status.md` and the deployment checkpoint were updated

## Troubleshooting

| Symptom | Safe response |
|---|---|
| External agent receives `401` | Verify the key ID exists and the key is unexpired/unrevoked; issue a replacement because the clear secret cannot be recovered |
| External agent receives `403 AGENT_IDENTITY_MISMATCH` | The request body names a different registration than the key. Correct the mapping; never introduce a global bypass key |
| `403` from Azure after a managed identity was recreated | Compare RBAC assignments and SQL contained user to the new principal; do not broaden roles |
| Worker Graph call returns `403` | Compare the exact eight-role workflow-v3 worker allowlist and consent state; Registry roles do not belong on the worker |
| API Registry OBO returns `401`/`403` | Verify the signed-in token has `Gateway.Administrator`, valid `oid`, and `access_as_user`; read back both admin-consented delegated Registry scopes and the exact API-managed-identity FIC without printing tokens/assertions |
| Agent ID token has the wrong audience, `appid`/`azp`, or role | Stop; do not log the token. Verify `fmi_path`, blueprint/child IDs, and only the Agent 365 observability assignment |
| Admin UI sign-in fails after a human credential rotation | Retain overlap, verify only the configured reference/version and redirect URI, and roll back the reference if necessary |
| A document or operator suggests a per-agent client secret/certificate | Treat it as the rejected workflow-v1 model and follow the blueprint FIC model above |
