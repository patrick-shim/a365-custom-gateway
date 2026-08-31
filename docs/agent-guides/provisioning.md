# Provisioning contributor guide

Follow the required reading order in `AGENTS.md` before changing provisioning. Read
the current deployment checkpoint and applicable runbook before any live action.

## Ownership

- Domain entities/enums/interfaces: `src/Gateway.Domain`
- Shared request/response contracts: `src/Gateway.Contracts`
- Orchestration/application handlers: `src/Gateway.Application`
- Agent Identity/Agent 365 adapters: `src/Gateway.Agent365`
- Purview runtime/policy automation: `src/Gateway.Purview`
- API-owned Registry/OBO action: `src/Gateway.Api`
- Durable worker: `src/Gateway.Provisioning.Worker`
- Bootstrap: `bootstrap`
- SQL/Bicep: `infrastructure`

## Registration identity contract

The Gateway is N:N. Each registration binds one generated external ID, one selected
reusable blueprint, one distinct child Agent ID, and one Gateway key lifecycle.
Ordinary external agents never supply managed-identity IDs or Entra tokens.

Blueprint compatibility is checked from the typed catalog and rechecked by the API.
Identifier equality does not make blueprint objects, applications, principals, or
child identities interchangeable.

## Durable workflow

The v3 worker uses seven stable persisted stage values:

1. Resolve Blueprint
2. Ensure Blueprint Principal
3. Configure Gateway Federation
4. Create Agent Identity
5. Assign Agent 365 Access
6. Register with Agent 365
7. Verify Agent 365 Connection

Do not reorder or repurpose persisted values. One stage may contain multiple
provider calls, but each external mutation must be discoverable and safe after
redelivery.

The worker performs the first five stages and waits at 71%. It never calls Registry.
A signed-in `Gateway.Administrator` completes Registry through the API's user-only
endpoint with `oid`, `access_as_user`, and delegated OBO.

## Registry invariant

The API:

1. acquires the session-owned SQL job lock;
2. verifies the exact completed workflow prefix;
3. pre-acquires delegated Registry access;
4. persists a creator-bound planned Registry ID;
5. emits at most one CLI-compatible POST;
6. persists HTTP 201 and the safe returned ID, using the planned ID only when the
   successful response omits one;
7. enqueues final verification only.

An unknown POST outcome is reconciled by exact GET of the planned ID. Never repeat
the POST. Safe retry after accepted Registry queues only final verification.

## Graph permissions

The worker allowlist is exactly:

- `Application.Read.All`
- `AppRoleAssignment.ReadWrite.All`
- `AgentIdentityBlueprint.Create`
- `AgentIdentityBlueprint.AddRemoveCreds.All`
- `AgentIdentityBlueprintPrincipal.Create`
- `AgentIdentityBlueprint.Read.All`
- `AgentIdentity.Create.All`
- `AgentIdentity.Read.All`

Registry permissions are the API app's delegated
`AgentRegistration.ReadWrite.All` and `AgentRegistration.Read.All` scopes. Do not
assign them to the worker or introduce app-only Registry access.

The API OBO client uses a managed-identity signed assertion and the sole
`api://AzureADTokenExchange` FIC audience. No client-secret fallback is permitted.

## Idempotency and recovery

- Discover exact provider state before creating.
- Persist intent/evidence before crossing an external mutation boundary.
- Use SQL locks for concurrent ownership, not as an exactly-once claim.
- Treat Service Bus as duplicate-delivery capable.
- Keep v3 on `gateway-provisioning-v3`; never attach it to an older queue.
- Preserve failed jobs and dead-letter messages until an incident/recovery decision.
- Fail closed on unknown, unauthorized, unsupported, or mismatched state.

## Purview profiles

Profile assignment is optional. Ordinary unprotected registration remains available
when the core admission path is open. A profile-backed registration calls policy
automation only after blueprint resolution and fails before child creation unless
exact policy readback succeeds.

The automation must keep scopes separate:

- Know Your Data: fixed enterprise-AI-apps ID
  `ee1680d0-702f-4090-b26c-c49091e86531`, Group;
- DLP: resolved blueprint application ID, Individual;
- both: Application enforcement plane.

Preserve existing reviewed DLP locations. Never merge blueprint IDs into the KYD
Group. Certificate/PFX material is loaded through the approved private path and may
not appear in environment output, command arguments, logs, state, or tests.

## Final verification

After accepted Registry creation, final verification re-reads blueprint, principal,
Gateway FIC, child identity, OtelWrite assignment, and mapped child token/role state.
Bounded retries may tolerate documented provider read-after-write lag, but a timeout
must remain a truthful failure/manual state.

## Testing

1. Add focused unit tests for idempotency, discovery, timeout, redelivery, and
   unknown-outcome behavior.
2. Test negative permission, identifier, tenant, and provider-shape cases.
3. Run the affected project tests, then full solution tests and Release build.
4. Run Pester/source/Bicep gates for bootstrap or policy-automation changes.
5. Never let automated tests mutate a live tenant.
6. Treat a local pass as source evidence only; live deployment needs independent
   authorized readback.

Update implementation and deployment checkpoints after verified changes without
copying secret material or raw content.
