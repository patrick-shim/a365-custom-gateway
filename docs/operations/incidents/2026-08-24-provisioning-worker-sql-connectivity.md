# Development Incident: Provisioning Worker SQL Connectivity

**Date:** 2026-08-24

**Status:** Resolved for the current VNet workflow-v2 path; retained historical incident

**Environment:** Development (`rg-agent-gateway`)

**Impact classification:** All development agent provisioning blocked; API and Admin
UI remained available

**Latest evidence checkpoint:** 2026-08-24T10:30:51Z (2026-08-24 19:30:51 KST)

> **Current handoff note:** This incident preserves the chronology of the deployed
> workflow-v1 failure. The seven-stage workflow v2 and its VNet worker are now
> deployed, contained SQL access is verified, and this incident is not the current
> canary blocker. Use
> [`../development-deployment-status.md`](../development-deployment-status.md) and
> [`../../implementation-status.md`](../../implementation-status.md) for the resume
> point; do not replay this incident's operation.

## Summary

A real agent registration created provisioning operation
`3c156bdc-4aa3-4802-81f8-5595e037d0e5`, but the operation remained `Pending` at `0%`.
The provisioning worker was platform-ready yet could not connect to Azure SQL because
it was hosted in a different, non-VNet Container Apps environment from the API and
Admin UI. Azure SQL public access was disabled and the database was reachable only
through its private networking path.

No provisioning step was recorded as running or completed. One message was present in
the provisioning DLQ at the initial checkpoint. The count was two after the later
gates-off blue/green bootstrap; neither message was payload-inspected or correlated.

## Timeline

| Time (UTC) | Event |
|---|---|
| 2026-08-24 06:48:25 | The Admin UI displayed the operation start and began polling. The UI labeled this value `local`; the raw API timestamp was not independently captured during the read-only diagnosis. |
| 2026-08-24 06:51 | Worker console logs showed repeated SQL error `47073`, stating that the connection was denied because public network access was disabled. |
| 2026-08-24 07:36 | API health, readiness, and database checks returned HTTP 200; Admin UI health returned HTTP 200. The worker remained platform `Running`. |
| 2026-08-24 07:36 | The provisioning queue reported `0` active, `0` scheduled, and `1` dead-lettered message with maximum delivery count `10`. |
| 2026-08-24 07:36 | Deployment inspection confirmed API/Admin UI in `cae-a365gw-dev-vnet` and worker in separate `cae-a365gw-dev`. |
| 2026-08-24 09:54 | Scoped deployment completed a newly named worker configured with minimum replicas zero and no scaler in `cae-a365gw-dev-vnet`, the dedicated credential vault, and bootstrap-only Azure RBAC. The historical worker was unchanged. |
| 2026-08-24 09:56 | The digest-pinned API revision was healthy with its registration gate false; the new worker was digest-pinned with processing, outbox relay, provisioning, and Registry preview disabled. |
| 2026-08-24 10:01 | The queue reported `0` active, `0` scheduled, and `2` DLQ messages; neither payload was inspected. |
| 2026-08-24 10:30 | Read-only correction showed the new revision had retained one ready replica since `09:55:57Z`, with `rules: null`. Both disabled-service startup messages were present, all execution gates remained off, and the queue was unchanged. Replica absence is not used as the safety proof. |

## Root cause

The worker did not share the API/Admin UI network topology:

- API and Admin UI: `cae-a365gw-dev-vnet`, with an infrastructure subnet.
- Worker: `cae-a365gw-dev`, without an infrastructure subnet.
- Azure SQL: public network access disabled and a private endpoint present.

The worker therefore could not load the agent and provisioning job from SQL. Repeated
message delivery could not advance the operation.

## Contributing conditions

- Container Apps reported the worker and replica as running/ready even while its
  required SQL dependency was unreachable.
- The worker had no deployment gate proving database connectivity from its actual
  Container Apps environment.
- The live operation view had no worker progress to report, so it remained at the
  initially persisted pending state.
- At this incident checkpoint, the **deployed historical worker revision** used an
  unimplemented provisioning client, and its handler could record
  `NotImplementedException` as completed stub behavior. This issue did not cause the
  SQL failure, but it independently prevented a valid end-to-end result in that
  revision. A later fail-closed eight-step workflow-v1 adapter was placed on the
  separately named inert blue/green worker. The seven-stage workflow v2 has since
  superseded and deployed past that adapter. Its first bounded canary reached the
  worker/SQL path and failed later at typed-blueprint compatibility before any
  Microsoft mutation; see the current deployment checkpoint.

## Impact

- The affected operation did not provision Microsoft Entra or Agent 365 resources.
- Development provisioning was unavailable for all requests requiring this worker.
- API and Admin UI availability were not affected.
- No data loss was proven. Both dead-lettered messages were retained and neither was
  inspected, replayed, completed, settled, or purged.

## Evidence

- Initial API revision `ca-gateway-api-dev--obs-20260824-145803-api`: digest pinned,
  `Running`, `/health`, `/health/ready`, and `/health/checks` HTTP 200.
- Current gates-off API revision `ca-gateway-api-dev--gatepin-20260824-1856`:
  digest pinned, healthy at one replica, and
  `Provisioning__ExecutionEnabled=false`; all three health endpoints returned 200.
- Admin UI revision `ca-gateway-admin-dev--obs-20260824-145803-ui`: digest pinned,
  `Running`, `/health` HTTP 200, signed-in operation route rendered.
- Historical worker revision `ca-gateway-worker-dev--obs-20260824-145803-w0`: digest pinned,
  platform `Running`, processing enabled, ready replica with zero restarts.
- Worker logs: repeated SQL error `47073` caused by disabled public network access.
- Initial Service Bus evidence: queue `Active`, active `0`, scheduled `0`, DLQ `1`,
  maximum delivery count `10`. Later evidence at `10:01:43Z`: active `0`, scheduled
  `0`, DLQ `2`, with no payload inspection or correlation. The same counts remained
  at `10:30:51Z`.
- Blue/green worker revision `ca-gateway-worker-dev-vnet--inert-20260824-1855`:
  digest pinned in the approved VNet, configured `0..1`, no scaler, one platform-
  retained ready replica, and all worker/outbox/provisioning/Registry gates off. Live
  logs confirm Service Bus processing and outbox relay are disabled. It has dedicated-
  vault and ACR access only.

No secret, credential, token, message body, prompt, or response content was accessed or
recorded in this incident document.

## Containment and safety

No Azure mutation was made during the diagnostic checkpoint; the later scoped
gates-off bootstrap is recorded separately above. Do not inspect, replay, settle, or
purge either DLQ message while the network fault or historical deployed behavior
remains. The known operation has a legacy seven-step shape and is non-resumable under
workflow v2; neither message has been payload-correlated to it. A replay can
redeliver a failing or incompatible message, and a purge would remove evidence and
the recovery option before correlation.

## Action items

| Action | Owner | Status |
|---|---|---|
| Bootstrap a newly named worker in the approved VNet-enabled Container Apps environment with processing/registration/execution/outbox disabled; verify private SQL connectivity, then obtain fresh authority before historical-worker cutover. | Codex/Claude shared handoff | Bootstrap complete; SQL contained user/connectivity proof pending |
| Add a worker deployment/readiness check that proves required SQL access rather than relying on Container Apps `Running`. | TBD | Open |
| Implement and test the real Graph/Agent 365 provisioning client. | Codex/Claude shared handoff | Workflow v2 complete and locally validated; inert v2 deployment and live verification pending |
| Remove the handler behavior that marks `NotImplementedException` provisioning steps as completed. | Codex/Claude shared handoff | Removed in current source; deployed VNet worker remains prior v1 and gates off |
| Inspect each DLQ message non-destructively and correlate it to an operation only after the code and network fixes. | TBD | Blocked |
| Review idempotency and approve an explicit replay, retry, or discard decision. | TBD | Blocked |
| Verify a newly authorized development provisioning operation reaches a truthful terminal state and creates the expected external resources. | TBD | Blocked |

## Resolution criteria

This incident can be closed only when:

1. Worker database connectivity succeeds from its deployed revision.
2. Queue processing produces no SQL network error and the DLQ disposition is recorded.
3. The real fail-closed provisioning client is deployed for the authorized
   development canary; no stub completion path remains. Production support remains a
   separate gate because the Registry provider is beta.
4. An explicitly authorized end-to-end development test reaches a truthful terminal
   state, and external resources are independently verified.
5. [`../development-deployment-status.md`](../development-deployment-status.md) is
   updated with a new read-only checkpoint.
