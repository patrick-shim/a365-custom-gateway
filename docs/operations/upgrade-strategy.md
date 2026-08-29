# Upgrade Strategy Runbook

This runbook covers the deployment and upgrade strategy for the A365 Custom Gateway. It includes container image versioning, blue-green deployments via Container Apps revision management, database migration procedures, rollback processes, canary releases, and version compatibility.

This runbook upgrades an existing evidence-bearing deployment. For a new clean
subscription, use [`../../bootstrap/README.md`](../../bootstrap/README.md) and its
resumable bootstrap. A deleted completed resource group is not an automatic
bootstrap replay: preserve state and choose a separately reviewed disaster-recovery
procedure or a new isolated deployment. First deployment does not bypass the
recovery, retained-message, canary, or SQL-finalization controls below.

## Current workflow-v3 boundary (authoritative)

For the current development rollout, Sections 1 and 2 are generic/future reference
only. Do **not** resume by running their tag-based update, traffic-shift, or revision-
deactivation snippets. Workflow v3 runs explicit continuous mode in development
with its isolated queue, delegated consent, API-app FIC, worker eight-role allowlist,
and Active create-new/reuse-existing registrations. Staging and production retain
exact-bound admission. Exact release counts live in the implementation status.

Three bounded canaries are retained separately. The first failed GET-only at
`ResolveBlueprint` for an incompatible blueprint and made no Microsoft mutation.
The second selected a compatible blueprint, received HTTP 201 from exactly one FIC
POST, and failed closed when an immediate list read was stale. Later read-only
reconciliation proved exactly one matching FIC, with the expected name, issuer,
worker subject, and exactly one `api://AzureADTokenExchange` audience. It created no
child Agent ID, Agent 365 role, Registry record, or telemetry mapping. The third
GET-reused the FIC, created a child Agent ID, assigned OtelWrite, then received
HTTP 500 from Registry without a durable ID. The v2 queue is `0/0/3`; all
registrations/messages are retained and finalize is unapplied. Do not retry or
attach the v2 canary. Its exact read-only Registry/Admin Center reconciliation
remains a separate historical action; Admin Center absence is not
API proof that the backend create had no effect.

Current revisions are API `ca-gateway-api-dev--purviewguard-20260828222324` on
digest `sha256:5275b3adcdb3e17f39e7b7466fc989bfeae04904f64f85226931be19c6e939b7`
and worker `ca-gateway-worker-dev-vnet--rbacrefresh-202608282058` on digest
`sha256:9dad873fe49b17c55677674688616c9770f8e3810c878702011632dda9dd7c9e`.
The v3 queue is `0/0/10`, v2 is `0/0/3`, and v1 is `0/0/2`. All retained messages
remain untouched. SQL public access is disabled and finalization is unapplied.
Before action, follow [`agent-guides/provisioning.md`](../agent-guides/provisioning.md)
and the exact checkpoint in
[`development-deployment-status.md`](development-deployment-status.md).

Workflow v3 keeps seven persisted stages but gives the worker only stages 0-4 and 6.
The worker pauses at 71%; the API's signed-in administrator OBO action creates/reads
the Registry record and reaches 85%; the worker then performs final verification.
The Registry POST is one-shot and CLI-compatible: the API persists and sends a
creator-bound planned `id` plus the reviewed preview-provider `managedByAppId`, then
accepts and persists the safe returned ID on HTTP 201 (using the planned ID only
when a successful response omits one). Unknown outcomes permit exact planned-ID GET
only and never a second POST. The provisioning-state planned-ID/app-only helpers
remain historical; the API attempt planned ID is current.

Historical superseded attempt: after four no-submission windows, the next exact registration window succeeded for
external ID `agent-v3demo-20260827030009-3c870882`. It created Gateway registration
`583777f0-c601-4c09-9e28-27dab51ae375`, operation
`5c4ba41d-24e5-473c-9126-f89f37f7bb18`, child Agent ID
`0a2e20d5-6299-4e02-a94e-0c6232a55113`, and safe key ID
`47b13283-5be7-4fc2-88d2-7fef34642214`. Stages 1--5 completed. One Administrator
action crossed the Registry create boundary exactly once and returned an ambiguous
outcome before a durable Registry ID. The operation is
`RequiresManualIntervention` at 71%; no final-stage enqueue, data-plane proof, or
telemetry landing exists.

The first delegated-completion attempt exposed a controller
`Nullable<Guid>.Value` bug before any user action. The fix plus regression coverage
passes focused architecture 105/105 and PowerShell parser 19/19. Recovery failed
closed; stale pre-registration evidence was rejected before re-Arm with no mutation,
and the exact-image worker rearm used revision
`ca-gateway-worker-dev-vnet--resume-124250`. Two corrected exact-operation windows
then closed without user action, exact-operation API logs, Registry request, or final
enqueue. Registration stays closed. Two pre-POST validation defects were fixed; the
later one-shot completion action produced the ambiguous outcome above. Reconcile
that exact historical result only through read-only Registry/Admin Center evidence. Never submit a second POST for
that historical registration or invoke its completion again. The distinct current
Active canary and exact next actions are in the implementation status.

### Historical post-registration delegated-completion rearm

This procedure records the rearm that was used before the consumed one-shot action.
It is **not authorized for the current manual operation**. Do **not** run
controller `Arm` or `OpenAdmission`. `RequireInitialAdmissionDatabaseState` correctly
requires zero active/awaiting v3 jobs and must reject the post-registration state.
Do not pass the post-registration evidence timestamp as
`ProvisioningOutboxVerifiedAtUtc` or use it as an initial-admission confirmation.

1. Keep API registration and delegated-action admission closed. Keep the worker
   inert while capturing a new phase-`verify`, repeat-one, zero-script artifact.
   Require publishable outbox 0; exactly one active workflow-v3 job and exactly one
   awaiting-administrator workflow-v3 job, both corresponding to operation
   `5c4ba41d-24e5-473c-9126-f89f37f7bb18`; active workflow-v2 jobs 3; and legacy
   jobs 2. Independently require queue baselines v3 `0/0/0`, retained v2 `0/0/3`,
   and historical `0/0/2`.
2. Re-arm only the workflow-v3 worker using the exact reviewed worker digest. This
   is the narrow update/readback used by historical resume revision
   `ca-gateway-worker-dev-vnet--resume-124250`: scale `1..1`; both Service Bus and
   provisioning-worker queue names `gateway-provisioning-v3`; max concurrent calls
   1; `OutboxRelay__Enabled=false`; worker processing and provisioning execution
   true; Registry provider `DirectRegistryPreview`; direct preview enabled; no
   command/argument override; and no `DATABASE_MIGRATOR_*` setting.
3. Read back one latest/ready active worker revision with the exact digest, scale,
   queue/configuration values, queue-scoped Receiver role, and clean runtime shape.
   Reverify API registration/delegated gates remain closed with no expiry or
   external/retry/operation binding. Do not alter the API during worker rearm.
4. Only after the refreshed operator session successfully re-reads the exact
   retained FIC, invoke controller `OpenDelegatedCompletion` exact-bound to operation
   `5c4ba41d-24e5-473c-9126-f89f37f7bb18`. That action intentionally does not require
   the initial-admission database-state assertion; it requires the worker already
   armed and independently verifies the closed API/configuration boundary.
5. After the user acts once or the window closes, run `Deactivate` and read-only
   `Status`; require API gates/bindings cleared, worker inert, and all three queue
   baselines preserved.

---

## Prerequisites

| Requirement | Details |
|---|---|
| **Azure role** | Contributor on the resource group |
| **Azure CLI** | v2.60+ |
| **Container registry** | `{acrName}.azurecr.io` |
| **Container Apps** | `{apiContainerAppName}` (API), `{workerContainerAppName}` (Worker) |
| **EF Core tools** | `dotnet-ef` tool installed |
| **GitHub Actions** | CI/CD pipeline configured (see Entra Setup Runbook, Step 5) |

### Login

```bash
az login --tenant {tenantId}
az account set --subscription {subscriptionId}
```

---

## 1. Container Image Versioning

### 1.1 Tagging Strategy

Container images may be tagged with the git SHA short hash for traceability, but tags
are mutable registry references. A deployment is immutable only when it resolves and
pins the reviewed `sha256:` digest; the current development revisions are
digest-pinned.

| Tag Format | Example | Use |
|---|---|---|
| `gateway-api:{gitShortSha}` | `gateway-api:a1b2c3d` | Primary deployment tag |
| `gateway-worker:{gitShortSha}` | `gateway-worker:a1b2c3d` | Primary deployment tag |
| `gateway-api:latest` | `gateway-api:latest` | Development convenience only (never used in staging/production) |

### 1.2 Image Build and Push (CI/CD)

The GitHub Actions workflow builds and pushes images on every merge to `main`:

```bash
# Build and tag the API image
docker build -t {acrName}.azurecr.io/gateway-api:${GIT_SHA_SHORT} \
  -f src/Gateway.Api/Dockerfile .

# Build and tag the Worker image
docker build -t {acrName}.azurecr.io/gateway-worker:${GIT_SHA_SHORT} \
  -f src/Gateway.Provisioning.Worker/Dockerfile .

# Push to ACR
az acr login --name {acrName}
docker push {acrName}.azurecr.io/gateway-api:${GIT_SHA_SHORT}
docker push {acrName}.azurecr.io/gateway-worker:${GIT_SHA_SHORT}
```

### 1.3 Verify Images in ACR

```bash
# List recent API images
az acr repository show-tags \
  --name {acrName} \
  --repository gateway-api \
  --orderby time_desc \
  --top 10 -o table

# List recent Worker images
az acr repository show-tags \
  --name {acrName} \
  --repository gateway-worker \
  --orderby time_desc \
  --top 10 -o table
```

---

## 2. Blue-Green Deployments via Container Apps Revisions

Azure Container Apps supports revision-based deployments. Each deployment creates a new revision, and traffic is shifted after health checks pass. This provides zero-downtime deployments with instant rollback capability.

### 2.1 Deployment Flow

```
Build Image --> Push to ACR --> Create New Revision --> Health Check --> Shift Traffic
```

### 2.2 Deploy a New Revision

```bash
GIT_SHA_SHORT="a1b2c3d"  # Replace with the actual git SHA

# Step 1: Create a new revision for the API Container App
az containerapp update \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --image {acrName}.azurecr.io/gateway-api:${GIT_SHA_SHORT} \
  --revision-suffix "v-${GIT_SHA_SHORT}"

# Step 2: Create a new revision for the Worker Container App
az containerapp update \
  --name {workerContainerAppName} \
  --resource-group {resourceGroup} \
  --image {acrName}.azurecr.io/gateway-worker:${GIT_SHA_SHORT} \
  --revision-suffix "v-${GIT_SHA_SHORT}"
```

### 2.3 Verify the New Revision

```bash
# Check that the new revision is running
az containerapp revision list \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --query "[].{name:name, active:properties.active, runningState:properties.runningState, trafficWeight:properties.trafficWeight, createdTime:properties.createdTime}" -o table
```

### 2.4 Health Check Verification

Before shifting traffic, verify that the new revision passes health checks:

```bash
# Get the new revision's FQDN (if using multi-revision mode with labels)
NEW_REVISION_FQDN=$(az containerapp revision show \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --revision {apiContainerAppName}--v-${GIT_SHA_SHORT} \
  --query "properties.fqdn" -o tsv)

# Test health endpoints
curl -s "https://${NEW_REVISION_FQDN}/health/checks" | jq .
curl -s "https://${NEW_REVISION_FQDN}/health/ready" | jq .
```

If Container Apps is configured in single-revision mode, the platform automatically checks the health probe before routing traffic. For multi-revision mode, use traffic splitting below.

### 2.5 Shift Traffic to the New Revision

```bash
# Shift 100% of traffic to the new revision
az containerapp ingress traffic set \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --revision-weight {apiContainerAppName}--v-${GIT_SHA_SHORT}=100
```

### 2.6 Deactivate the Old Revision

After verifying the new revision is stable (recommended: wait at least 30 minutes in production):

```bash
# List all active revisions
az containerapp revision list \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --query "[?properties.active==\`true\`].name" -o tsv

# Deactivate the old revision (keep it available for emergency rollback)
az containerapp revision deactivate \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --revision {oldRevisionName}
```

> **Note:** Deactivated revisions consume no resources but can be reactivated instantly for rollback.

---

## 3. Database Migration Strategy

> **Current prepared-schema state (2026-08-27):** the repository does not contain
> an EF Core migrations set, and the deployment workflow does not currently apply
> database migrations. Development already applied and verified the idempotent SQL
> sequence containing
> `infrastructure/sql/20260824_agent_identity_workflow_v2.sql` and
> `infrastructure/sql/20260825_agent_ingress_credentials.sql`, and
> the prepare script `infrastructure/sql/20260825_scoped_idempotency.sql`, followed by
> `infrastructure/sql/20260825_ingress_rate_limit_buckets.sql`. Do not rerun those scripts
> merely to refresh evidence. Apply the same reviewed prepare sequence before a new
> environment receives the N:N runtime. The separate
> `infrastructure/sql/20260825_scoped_idempotency_finalize.sql` was designed as a post-canary
> phase for this development rollout. The continuous workflow-v3 demo has since
> reached `Active` and passed data-plane/downstream evidence, but finalize remains
> intentionally unapplied until a separate schema/rollback review authorizes it. The
> retained workflow-v2 Registry ambiguity remains a separate read-only
> reconciliation action and must not be retried or attached to this canary. First rehearse both
> phases and recovery on a disposable copy. The EF commands and CI example below
> remain the target migration process, not evidence that it is wired into today's
> pipeline.

The workflow-v2 script adds nullable/defaulted columns only; the ingress script adds
`AgentIngressCredentials` containing key ID, registration ownership, salt/hash, and
expiry/revocation metadata—never the clear key. Existing jobs are
backfilled as workflow version `1` and remain historical/non-replayable; it does
not rewrite their recorded step types or claim that Microsoft resources exist.
The scoped compound index is a storage-integrity guard. Atomic first-use behavior is
implemented separately with an exclusive transaction-owned SQL application lock held
from replay lookup through side effects and commit. Local race tests pass; real SQL
Server multi-replica/staging stress remains a production-readiness gate. The limiter
script creates only fixed-minute global/registration/credential bucket counters.
Provisioning-stage concurrency is protected separately: SQL Server holds a dedicated
session-owned `sp_getapplock` keyed by job ID for the entire stage attempt. It is
implemented/tested locally but still needs real SQL multi-replica/failover stress.

### 3.1 Required disposable-copy rehearsal

This rehearsal completed for the current development rollout. Repeat it for a new
schema change or recovery checkpoint, never merely to manufacture a newer timestamp.
It is a rehearsal only; do not point `sqlcmd`, the API, or the Worker at the live
development database during these steps.

1. Create an isolated, disposable copy of the development database using the
   approved Azure SQL copy/restore process. Record the source database resource ID,
   source recovery point, disposable database resource ID, and UTC timestamps
   without recording connection material.
2. Before upgrading the copy, export ordered evidence for every row in
   `ProvisioningJobs` and `ProvisioningJobSteps`, including job IDs,
   `AgentRegistrationId`, existing job status/type, step IDs, `OrderIndex`,
   `StepType`, and step status. Also record the row counts for those two tables.
3. Preserve a second disposable pre-upgrade recovery point (a database copy or
   tested point-in-time restore target) so the rehearsal can prove recovery without
   altering the source development database.
4. Apply the four pre-cutover scripts in their documented order to the first
   disposable copy. Run that prepare batch a second time to prove its guards are
   idempotent.
5. Verify the five workflow-v2 columns on `AgentRegistrations`
   (`BlueprintSelectionMode`, `AgentIdentityObjectId`, `BlueprintObjectId`,
   `RequestedBlueprintObjectId`, and `RequestedBlueprintDisplayName`) and
   `ProvisioningJobs.WorkflowVersion`. Verify `AgentIngressCredentials` has the
   reviewed foreign key and lookup indexes and only verifier metadata. Verify the
   scoped idempotency columns/index named in the current checkpoint. Verify
   `IngressRateLimitBuckets` has the compound scope primary key, scope/count checks,
   UTC window/count metadata only. Do not accept a runtime-managed-identity column,
   raw-key column, authorization header, or request content.
6. Verify pre-existing idempotency rows remain present with NULL
   `AgentRegistrationId`, the old globally unique key-only index is **still present**,
   and the filtered unique compound index exists. The old index keeps a legacy API
   traffic rollback compatible during cutover. Legacy rows have no trustworthy
   registration ownership and must not be backfilled, replayed, or treated as N:N
   cache hits; a matching unexpired legacy key fails closed.
7. Simulate and record the post-cutover stop gate: N:N API behavior verified and no
   legacy API writer/traffic remains. Only then apply
   `20260825_scoped_idempotency_finalize.sql` twice on the disposable copy.
8. Verify finalization dropped only the global unique key-only index, retained the
   filtered scoped index and every NULL-scope legacy row, and did not change cached
   response data. Do not simulate an old API traffic rollback after this point.
9. Compare the ordered before/after evidence. Row counts, identifiers, recorded
   legacy step order/types/statuses, and all pre-existing values must be unchanged;
   every pre-existing job must read `WorkflowVersion = 1`. No legacy job or step is
   resumable merely because the column now exists.
10. Rehearse recovery by restoring the preserved pre-upgrade recovery point into a
   new disposable database. Verify the original schema and the same ordered legacy
   job/step evidence there. Do not test recovery by overwriting development.
11. Delete disposable resources only under the approved cleanup procedure after the
   evidence has been reviewed and retained; cleanup itself is not implied by this
   runbook.

**Stop gate:** do not apply the prepare phase to development if creation/restoration
of the disposable copies fails, any second execution fails, any legacy row or step
changes, any existing job is not version `1`, the global index is absent before
finalize, or any expected schema assertion differs. Never run finalize merely because
the SQL parses; its API-cutover/zero-old-traffic gate is mandatory.

### 3.2 Apply in development after the rehearsal gate

The four prepare deltas are already applied in current development and
scoped-idempotency finalization is intentionally unapplied. Do not re-run this phase
as the next canary action. The current evidence set is:

- `artifacts/deployment-evidence/live-prepare-20260824.json` is the immutable
  two-pass prepare provenance. It contains the current SHA-256 hash of each of the
  four reviewed scripts and proves workflow v2 ready with the legacy index retained.
  Do not rerun live DDL merely to refresh this artifact's timestamp.
- The retained recovery copy is `GatewayDb-v2-recovery-20260826025402`. The first
  worker-identity baseline attempt stopped before any schema action because of
  inherited contained-user state; the worker was restored to its inert runtime
  revision before verification continued.
- `artifacts/deployment-evidence/recovery-baseline-20260826.json`, verified through
  the API identity at `2026-08-26T03:01:23.76017Z`, is phase `baseline`, repeat one,
  has no scripts, and proves that the distinct recovery copy has workflow v2 absent
  and one legacy global index.
- `artifacts/deployment-evidence/live-state-20260826.json`, captured read-only at
  `2026-08-26T03:06:13.3306396Z`, is phase `verify`, repeat one, and has no scripts.
  It proves live `GatewayDb` has workflow v2 ready, one legacy global index, zero
  publishable outbox rows, two workflow-v2 jobs, and two legacy jobs.
- `artifacts/deployment-evidence/live-state-20260826-arm-preflight.json`, captured
  read-only at `2026-08-26T03:40:03.8854162Z`, is phase `verify`, repeat one, and has
  zero scripts. It proved the same state and supplied the exact outbox timestamp for
  the completed `WhatIf`/`Arm` rehearsal. It must be regenerated before another
  activation after the short outbox window ages.
- `artifacts/deployment-evidence/live-state-20260826-canary.json`, captured at
  `2026-08-26T07:11:03.2622069Z`, proved workflow v2 true, legacy index one, outbox
  zero, and workflow-v2/legacy job counts two plus two for the submitted canary.
- `artifacts/deployment-evidence/live-state-20260827-v3-canary-0713.json`, captured
  read-only at `2026-08-27T07:13:51.4766174Z`, proved outbox zero, active/awaiting
  workflow-v3 jobs zero, active workflow-v2 jobs three, and legacy jobs two for the
  first v3 no-submission window.
- `artifacts/deployment-evidence/live-state-20260827-v3-canary-0841.json`, captured
  read-only at `2026-08-27T08:41:38.2934168Z`, proved the same zero-outbox and job
  boundaries for the second and third no-submission windows.
- `artifacts/deployment-evidence/live-state-20260827-v3-canary-0949.json`, captured
  read-only at `2026-08-27T09:49:10.6200517Z`, is phase `verify`, repeat one, and
  contains `Scripts: []`. It proves publishable outbox zero, active/awaiting
  workflow-v3 jobs zero, active workflow-v2 jobs three, and legacy jobs two for the
  fourth no-submission window. That window closed at operator cutoff
  `2026-08-27T10:11:26.1449657Z` (API crash deadline
  `2026-08-27T10:13:56.3860457Z`) without a registration, job, key, Agent ID,
  Registry, or data-plane mutation. Final Deactivate produced the then-current
  closed/inert revisions.
- `artifacts/deployment-evidence/live-state-20260827-v3-canary-1158.json`, captured
  read-only at `2026-08-27T11:58:17.1952233Z`, was the fresh evidence accepted for
  the successful registration Arm. It is now historical/stale because registration
  created a job and changed live SQL state; never reuse it for delegated completion.
- Development SQL public network access is policy-enforced `Disabled`, and
  `20260825_scoped_idempotency_finalize.sql` remains unapplied.

The historical submitted v2 canary failed outcome-unknown at Registry. Preserve the
immutable, hash-validated prepare provenance and distinct recovery baseline; do not
rerun SQL or finalize. The workflow-v3 rearm described in this historical checkpoint
was completed later; old evidence remains unusable as an activation grant.

The approved workflow-v3 private verifier image is
`acra365gwdevs4a3t2.azurecr.io/gateway-db-migrator@sha256:931c8db13dac2e341e916dd638d497180643c15d8f6e8fe1610cf36a9a953dd8`.
The older `sha256:df5f1c942159bc67f8a3dff3f70ac4d203569cff9c6e16d595d1701c277afc17`
is the historical workflow-v2 verifier and must not be used for workflow-v3 evidence.
Run the workflow-v3 verifier only temporarily on the inert VNet worker under managed
identity, with
non-secret `DATABASE_MIGRATOR_*` settings for server/database, phase `verify`,
repeat `1`, `DATABASE_MIGRATOR_EVIDENCE` for the evidence path, stay-alive, and required
`DATABASE_MIGRATOR_REPOSITORY_ROOT=/repo`. Earlier attempts omitted the repository
root, failed before SQL, and restored inert. Retrieve the artifact through Azure exec
as wrapped base64-only lines and decode locally; plain JSON can be concatenated with
the WebSocket-close trailer. Then restore the reviewed worker runtime image, remove
all `DATABASE_MIGRATOR_*` settings, and read back the exact digest, clean command/
argument shape, inert gates, and scale before activation.

The migrator does **not** read `DATABASE_MIGRATOR_EVIDENCE_FILE`. A temporary
verifier revision that used that wrong name completed its zero-script read-only
verification but emitted no artifact; the corrected revision used
`DATABASE_MIGRATOR_EVIDENCE` and produced the `0949` evidence above. Neither attempt
performed SQL mutation, and the final restore removed every migrator setting.

For auditability, the following records the controlled apply sequence for these
four prepare scripts. It is a reference for a new environment or an explicitly
authorized recovery, not an instruction to reapply the completed development
prepare phase for this canary. Establish a **fresh live-change recovery checkpoint**
immediately before any such database mutation:

1. Reverify that API registration/retry admission is false and that the new VNet
   worker's processing, outbox relay, provisioning execution, and direct Registry
   provider remain disabled. The deployed API outbox relay remains the existing
   publisher path; prove there is no pending/due provisioning outbox work, the queue
   still has zero active and zero scheduled messages, and no component or operator
   will intentionally produce a new message during the schema change. Leave the
   historical worker unchanged at this stage. Absolute receiver isolation requires
   the later, separately authorized cutover stop and is not implied by schema-upgrade
   authority.
2. Capture current ordered pre-upgrade schema and legacy job/step evidence using the
   same fields and row-count assertions as the rehearsal. Do not reuse the earlier
   disposable-copy snapshot as current evidence.
3. Verify the development database's current point-in-time-restore retention and
   create or identify a current recoverable copy/restore point plus a separately
   named, isolated restore target. Record resource IDs and UTC timestamps without
   connection material. The recovery action must restore to a new database; it must
   never overwrite development in place.
4. Confirm in advance the fail-closed decision: if the script or any post-change
   assertion fails, keep all execution gates off, stop deployment, restore into the
   isolated target, compare it with the pre-change evidence, and obtain explicit
   authority before redirecting an application or changing/deleting development.

Only after that recovery checkpoint is verified may a private-DNS-aware runner
execute the four pre-cutover scripts in order against the intended database. Repeat
the schema and legacy-row assertions immediately afterward and before deploying
workflow-v2 code. The command must use the intended server/database values; never
paste or echo credentials.

```powershell
sqlcmd `
  -S "tcp:{sqlServerName}.database.windows.net,1433" `
  -d "{databaseName}" `
  -G `
  -i "infrastructure/sql/20260824_agent_identity_workflow_v2.sql"

sqlcmd `
  -S "tcp:{sqlServerName}.database.windows.net,1433" `
  -d "{databaseName}" `
  -G `
  -i "infrastructure/sql/20260825_agent_ingress_credentials.sql"

sqlcmd `
  -S "tcp:{sqlServerName}.database.windows.net,1433" `
  -d "{databaseName}" `
  -G `
  -i "infrastructure/sql/20260825_scoped_idempotency.sql"

sqlcmd `
  -S "tcp:{sqlServerName}.database.windows.net,1433" `
  -d "{databaseName}" `
  -G `
  -i "infrastructure/sql/20260825_ingress_rate_limit_buckets.sql"
```

Never enable code that expects a schema delta until every corresponding post-change
assertion passes.

### 3.3 Finalize scoped idempotency after the verified bounded canary

Keep API registration/provisioning admission and worker execution off. Deploy and
verify the N:N API against the prepared schema, prove caller-registration-first
atomic activity, batch, and interaction replay/conflict behavior plus safe limiter
decisions, and prove every legacy API revision is at zero traffic. Keep the global
index present while the fixed development canary controller arms the worker first,
opens only the bounded admission window for the one reviewed registration, verifies
the canary, and returns API admission and worker execution to inert. Opening
requires both the API boolean gate and a future UTC
`Provisioning__AdmissionExpiresAtUtc`; the API rejects new registrations/retries
after that timestamp even if the controller or operator PC crashes.
`OpenAdmission` permits a 30--300 second operator window that starts after revision
readiness and a 60--300 second revision-rollout allowance, with a hard combined
exposure ceiling of 600 seconds. Exact-binding mode also admits only one configured
external ID and leaves retry unset; delegated Registry completion later uses a
separate exact operation-ID window. This local/cutover proof does not replace real SQL
multi-replica/staging stress. If any check or canary stage fails or is inconclusive
**before** finalize, keep execution gates off and retain the old-API
rollback-compatible global index.

Only after all cutover and canary evidence passes, deactivation is verified, and old
API traffic is rechecked at zero:

```powershell
sqlcmd `
  -S "tcp:{sqlServerName}.database.windows.net,1433" `
  -d "{databaseName}" `
  -G `
  -i "infrastructure/sql/20260825_scoped_idempotency_finalize.sql"
```

Verify only the old global key-only index was removed; the filtered compound index,
foreign key, and all NULL-scope legacy rows remain. After this point, an old API
revision is not a normal traffic rollback target: fail closed and roll forward, or
obtain explicit approval for a reviewed database-compatibility recovery. Never
recreate/drop indexes or delete legacy rows ad hoc. The approved retention process,
not this migration, ages legacy rows out.

### 3.4 Migration rules

The current additive SQL upgrade and any future EF Core migrations are applied
**before** their dependent application deployment. All schema changes must follow
these rules:

| Rule | Description |
|---|---|
| **Backward-compatible only** | New columns must have defaults or be nullable. Existing columns are never renamed or removed in the same release. |
| **Additive operations** | New tables, new columns, new indexes. Never drop a column that the running code still references. |
| **Two-phase removal** | To remove a column: Phase 1 -- deploy code that no longer reads the column. Phase 2 (next release) -- migration removes the column. |
| **No data-destructive changes** | Migrations must never DELETE data. Use soft-delete. |
| **Idempotent checks** | Migrations should use `IF NOT EXISTS` guards where possible. |

### 3.5 Target EF pre-deployment procedure (not implemented today)

The following is a future migration-set reference only. Do not run it for the current
workflow-v2 upgrade; use the reviewed SQL script and rehearsal sequence above.

```bash
# Step 1: List pending migrations
"C:\Program Files\dotnet\dotnet.exe" ef migrations list \
  --project src/Gateway.Infrastructure \
  --startup-project src/Gateway.Api \
  --connection "Server={sqlServerName}.database.windows.net;Database={databaseName};Authentication=Active Directory Default;" \
  --no-build

# Step 2: Generate the SQL script for review (always review before applying)
"C:\Program Files\dotnet\dotnet.exe" ef migrations script \
  --project src/Gateway.Infrastructure \
  --startup-project src/Gateway.Api \
  --idempotent \
  --output migrations-{GIT_SHA_SHORT}.sql

# Step 3: Review the generated SQL script
# Look for: DROP, DELETE, ALTER COLUMN (type changes), data-destructive operations

# Step 4: Apply the migration
"C:\Program Files\dotnet\dotnet.exe" ef database update \
  --project src/Gateway.Infrastructure \
  --startup-project src/Gateway.Api \
  --connection "Server={sqlServerName}.database.windows.net;Database={databaseName};Authentication=Active Directory Default;"
```

### 3.6 Target CI/CD migration flow (not implemented today)

If a future pipeline adds migrations, they should run as a separate reviewed step
before the Container App deployment. The current workflow does not contain this job:

```yaml
# .github/workflows/deploy.yml (relevant section)
jobs:
  migrate:
    runs-on: ubuntu-latest
    steps:
      - uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Apply EF Core migrations
        run: |
          dotnet tool restore
          dotnet ef database update \
            --project src/Gateway.Infrastructure \
            --startup-project src/Gateway.Api \
            --connection "Server={sqlServerName}.database.windows.net;Database={databaseName};Authentication=Active Directory Managed Identity;"

  deploy:
    needs: migrate  # Deploy only after migrations succeed
    runs-on: ubuntu-latest
    steps:
      # ... deploy Container App revision
```

### 3.7 Target EF migration rollback procedure

> **Future EF reference only.** It does not apply to the current reviewed SQL
> workflow-v2/N:N phases. Current rollback/recovery always restores or copies the
> preserved recovery point into a **new named database**, verifies it, and redirects
> applications only under explicit approval. Never execute a `Down()` migration,
> rollback script, rename, or restore that overwrites the source development
> database for this rollout.

If a migration causes issues, reverse it by applying the previous migration:

```bash
# Roll back to a specific migration
"C:\Program Files\dotnet\dotnet.exe" ef database update {PreviousMigrationName} \
  --project src/Gateway.Infrastructure \
  --startup-project src/Gateway.Api \
  --connection "Server={sqlServerName}.database.windows.net;Database={databaseName};Authentication=Active Directory Default;"
```

> **Warning:** Rollback only works if the migration's `Down()` method is properly implemented. Always test migration rollbacks in a non-production environment.

For emergency situations where `Down()` is not available:

```bash
# Generate a rollback script
"C:\Program Files\dotnet\dotnet.exe" ef migrations script \
  --project src/Gateway.Infrastructure \
  --startup-project src/Gateway.Api \
  {CurrentMigrationName} {PreviousMigrationName} \
  --output rollback-{GIT_SHA_SHORT}.sql

# Review and apply the rollback script manually
# sqlcmd or Azure Portal Query Editor
```

---

## 4. Rollback Procedure

### 4.1 Container App Rollback

To roll back to the previous revision:

```bash
# Step 1: Identify the previous stable revision
az containerapp revision list \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --query "sort_by([?properties.active==\`true\` || properties.active==\`false\`], &properties.createdTime)[-2:].{name:name, createdTime:properties.createdTime, active:properties.active}" -o table

# Step 2: Activate the previous revision (if deactivated)
az containerapp revision activate \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --revision {previousRevisionName}

# Step 3: Shift traffic back to the previous revision
az containerapp ingress traffic set \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --revision-weight {previousRevisionName}=100

# Step 4: Repeat for the Worker Container App
az containerapp revision activate \
  --name {workerContainerAppName} \
  --resource-group {resourceGroup} \
  --revision {previousWorkerRevisionName}

az containerapp ingress traffic set \
  --name {workerContainerAppName} \
  --resource-group {resourceGroup} \
  --revision-weight {previousWorkerRevisionName}=100
```

### 4.2 When to Rollback vs. Fix Forward

| Scenario | Decision | Reasoning |
|---|---|---|
| Health checks failing on new revision | **Rollback** | Immediate impact; fix and redeploy |
| Elevated error rate (>5% increase) | **Rollback** | User-facing impact; root cause unknown |
| Performance regression (p95 latency >2x) | **Rollback** | User-facing impact |
| Single non-critical bug | **Fix forward** | Deploy a patch; minimal user impact |
| Minor UI issue | **Fix forward** | No functional impact |
| Current workflow-v2/N:N SQL phase failure | **Keep gates off; restore/copy to a new database and verify before any redirect** | The reviewed SQL phases have no in-place `Down()` rollback; never overwrite development |
| Future EF migration failure | **Use its separately rehearsed recovery plan** | The generic EF guidance is not authorization for the current rollout |
| Security vulnerability in new code | **Rollback immediately** | Security takes priority |

### 4.3 Full Rollback Checklist

For a complete rollback (app + database):

1. [ ] Shift API traffic to previous revision.
2. [ ] Stop or restore the intended Worker gate configuration; never attach a v1
       worker to the v2 queue.
3. [ ] For current SQL phases, restore/copy the approved recovery point to a new
       database and verify it before any separately approved connection redirect.
4. [ ] Verify `/health/checks` returns healthy.
5. [ ] Verify `/health/ready` returns ready.
6. [ ] Verify external agent token acquisition works.
7. [ ] Verify provisioning pipeline functions.
8. [ ] Monitor error rates for 30 minutes.
9. [ ] Communicate status to stakeholders.

---

## 5. Canary Releases (Production)

For production deployments, use canary releases to gradually shift traffic to the new revision while monitoring for issues.

### 5.1 Canary Release Stages

| Stage | Traffic to New Revision | Monitoring Window | Proceed If |
|---|---|---|---|
| 1 | 10% | 15 minutes | Error rate < baseline + 1%, p95 latency < baseline + 20% |
| 2 | 50% | 30 minutes | Error rate < baseline + 0.5%, p95 latency < baseline + 10% |
| 3 | 100% | 60 minutes | Metrics stable at baseline |

### 5.2 Canary Deployment Commands

```bash
# Stage 1: 10% canary
az containerapp ingress traffic set \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --revision-weight \
    {previousRevisionName}=90 \
    {apiContainerAppName}--v-${GIT_SHA_SHORT}=10

# Monitor for 15 minutes (check Application Insights)
# KQL query to compare error rates between revisions:
# requests
# | where timestamp > ago(15m)
# | summarize
#     errorRate = countif(success == false) * 100.0 / count(),
#     p95_latency = percentile(duration, 95)
#   by cloud_RoleInstance
# | order by cloud_RoleInstance

# Stage 2: 50% canary
az containerapp ingress traffic set \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --revision-weight \
    {previousRevisionName}=50 \
    {apiContainerAppName}--v-${GIT_SHA_SHORT}=50

# Monitor for 30 minutes

# Stage 3: 100% promotion
az containerapp ingress traffic set \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --revision-weight {apiContainerAppName}--v-${GIT_SHA_SHORT}=100
```

### 5.3 Canary Abort

If metrics deteriorate at any stage:

```bash
# Abort: shift all traffic back to the previous revision
az containerapp ingress traffic set \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --revision-weight {previousRevisionName}=100
```

### 5.4 Monitoring During Canary

Key metrics to watch during canary stages:

```kusto
// KQL: Compare error rates between revisions
requests
| where timestamp > ago(30m)
| extend revision = tostring(customDimensions["kubernetes.io/revision"])
| summarize
    totalRequests = count(),
    failedRequests = countif(success == false),
    errorRate = round(countif(success == false) * 100.0 / count(), 2),
    p50_ms = round(percentile(duration, 50), 1),
    p95_ms = round(percentile(duration, 95), 1),
    p99_ms = round(percentile(duration, 99), 1)
  by revision
| order by revision asc
```

---

## 6. Version Compatibility Matrix

The API, database schema, and Worker must be compatible. Use this matrix to track version compatibility across releases.

### 6.1 Compatibility Rules

| Rule | Description |
|---|---|
| **API N + DB N** | Required. API version must be compatible with the current database schema. |
| **API N + DB N-1** | Target for future additive migrations. Current N:N code must not run before its four prepare scripts. |
| **API N-1 + DB N** | Valid only before scoped-idempotency finalize while the legacy global index remains. After finalize, old-API traffic rollback requires explicit database compatibility recovery. |
| **Worker N + API N** | Required. Worker and API must run the same contract version. |
| **Worker N + API N-1** | Best effort. Worker should handle messages from the previous API version. |

### 6.2 Version Tracking

Maintain a compatibility matrix in the repository:

| Release | API Version | DB Schema Version | Worker Version | Compatible With |
|---|---|---|---|---|
| v1.0.0 | `a1b2c3d` | Migration `20260801_InitialCreate` | `a1b2c3d` | DB: Initial |
| v1.1.0 | `e4f5g6h` | Migration `20260815_AddPurviewDecisionIndex` | `e4f5g6h` | DB: v1.0.0, v1.1.0 |
| v1.2.0 | `i7j8k9l` | Migration `20260823_AddReconciliationColumns` | `i7j8k9l` | DB: v1.1.0, v1.2.0 |

### 6.3 Breaking Change Protocol

If a release contains a breaking schema change (rare, requires two-phase approach):

1. **Phase A release:** Deploy new code that supports both old and new schema. Migration adds new columns/tables but does not remove old ones.
2. **Monitoring period:** 1 week minimum in production.
3. **Phase B release:** Deploy migration that removes old columns/tables. Code no longer references old schema.

---

## 7. Maintenance Windows and Communication

### 7.1 Maintenance Window Policy

| Environment | Maintenance Window | Notification Lead Time |
|---|---|---|
| Development | Any time | None |
| Staging | Business hours (Mon-Fri, 9 AM - 5 PM local) | 1 hour |
| Production | Off-peak (Tue-Thu, 2 AM - 6 AM UTC) | 48 hours |
| Emergency (any environment) | Immediate | Best effort |

### 7.2 Pre-Deployment Communication

**Subject:** A365 Gateway -- Scheduled Maintenance

```
Maintenance Type: {Routine Update | Security Patch | Database Migration | Infrastructure Change}
Environment: {Production | Staging}
Scheduled Start: {UTC datetime}
Expected Duration: {minutes}
Expected Impact: {None (zero-downtime) | Brief health check failures (< 30 seconds) | Service unavailable for N minutes}

Changes Included:
- {Change 1 description}
- {Change 2 description}

Rollback Plan: {Automatic rollback if health checks fail | Manual rollback within N minutes}

Contact: {on-call engineer contact}
```

### 7.3 Post-Deployment Communication

```
Deployment Status: {Completed Successfully | Rolled Back | Completed with Issues}
Actual Duration: {minutes}
Changes Applied: {Yes/No per change item}
Deployment Checkpoint: {UTC timestamp and repository checkpoint link}
Container Apps Environments: {API, Admin UI, and Worker environment names}
Worker Dependency Readiness: {SQL reachable | Blocked | Not verified}
Provisioning Queue: {active count, DLQ count, and disposition}
Provisioning E2E: {Verified with explicit authorization | Blocked | Not performed}

Issues Encountered: {None | Description}
Follow-up Required: {None | Description}
```

---

## Deployment Checklist

### Pre-Deployment

- [ ] Corrected controller tests and the complete repository gate pass against the
      source being deployed
- [ ] Container images built and pushed to ACR
- [ ] Immutable two-pass prepare provenance is hash-valid, the fresh distinct
      restore-to-new-database baseline is valid, and live finalize evidence is
      absent; EF guidance applies only after a real EF migration set exists
- [ ] Version compatibility verified (API N works with DB N-1)
- [ ] API, Admin UI, worker, SQL private endpoint, and Container Apps environment
      topology reviewed together
- [ ] Maintenance window communicated (production only)
- [ ] Rollback plan documented
- [ ] On-call engineer available

### Initial-registration deployment only

This checklist governs a new registration from the zero-active-v3 baseline. It is
not the resume path for the current manual 71% operation. That operation has already
consumed its one-shot create boundary and permits only read-only Registry/Admin
Center reconciliation. The historical rearm section above must not be reused.

- [ ] Current SQL prepare phase applied and verified against the preserved recovery
      evidence; live finalize remains unapplied through the bounded canary
- [ ] A new read-only phase-`verify`, repeat-one, zero-script live-state artifact
      was generated immediately before `Arm`; it proves publishable outbox zero and
      its `VerifiedAtUtc` is supplied unchanged as
      `ProvisioningOutboxVerifiedAtUtc`
- [ ] Controller `WhatIf` validates the exact prepare, live-state, recovery,
      retained-failure, revision, digest, queue, RBAC, and FIC inputs before `Arm`
- [ ] New Container App revisions created
- [ ] API, Admin UI, and worker revisions are attached to their intended Container Apps
      environments
- [ ] Health checks passing on new revisions
- [ ] Traffic shifted (canary stages for production)
- [ ] Metrics monitored during canary windows
- [ ] Full traffic cutover completed

### Post-Deployment

- [ ] After a successful bounded canary and verified inert gates, scoped-idempotency
      finalize applied at its documented gate and only the legacy global index removed
- [ ] `/health/checks` returns healthy
- [ ] `/health/ready` returns ready
- [ ] Admin UI `/health` returns healthy
- [ ] Worker dependency readiness is verified from the deployed revision, including
      private SQL connectivity; platform `Running` alone is insufficient
- [ ] Worker logs contain no unresolved SQL, identity, or Service Bus processing errors
- [ ] Provisioning queue active and DLQ counts are recorded; every nonzero DLQ has
      reviewed retained-evidence correlation or an explicitly authorized
      disposition. The current three v2 and two historical messages remain retained
      and are not replayed, received, peeked, settled, or purged
- [ ] Error rate within baseline
- [ ] P95 latency within baseline
- [ ] External Gateway key binding and worker-acquired child Agent 365 token are each
      verified without echoing either credential
- [ ] Provisioning contains no stub-success path and is verified end to end with an
      explicitly authorized development operation; otherwise deployment is recorded as
      blocked or not verified
- [ ] Old revisions deactivated (after stability period)
- [ ] `development-deployment-status.md` updated with a UTC checkpoint and evidence
- [ ] Post-deployment communication sent
