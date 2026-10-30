# Gateway runtime guide

## Installation

The terminal installer (`gateway.cmd init`) and React installer (`gateway.cmd gui`) use the same PowerShell engine, configuration schema, reviewed plan and verification. Follow [bootstrap](../../bootstrap/README.md) for tenant prerequisites and permissions. Both collect initial Content Safety and Purview settings; routine policy selection happens in the Console after setup.

The supported local topology is Docker Compose plus a Windows certificate-based Purview management host. Compose runs PostgreSQL, RabbitMQ, S3-compatible storage, the API, worker and Console. The base stack also starts an unwired Vault development container; the application does not currently read secrets from it. Default service credentials and host-file secret handling make this a development configuration.

## Files that belong to the running installation

| Path | Purpose |
| --- | --- |
| `bootstrap/config.json` | Ignored, non-secret deployment settings |
| `.bootstrap/state/` | Owned-resource checkpoints |
| `.bootstrap/secrets/` | Credentials, transport key and blueprint-specific development credentials |
| `.bootstrap/purview-catalog/` | Bootstrap-signed catalog migration source and connector identity material |
| `.bootstrap/purview-connector/` | Stable connector ID, authenticated command/result/checkpoint transport and heartbeat |
| `.bootstrap/purview-assignments/` | Authenticated assignment requests/results |
| `.bootstrap/tools/` | Published management host binaries |
| `.bootstrap/accepted-source/` | Source integrity material for reviewed installation plans |
| `deploy/runtime/.env.runtime` | Generated container configuration and secrets |

Do not delete active state to perform a source cleanup or normal rebuild. Missing credentials stop setup rather than silently rotating them. Back up credentials and database state according to the deployment's security policy; do not copy them into source control or issue reports.

`runtime.composeProjectName` and `runtime.credentialLabelPrefix` optionally pin existing deployment ownership names. Leave them unchanged on an existing installation. New installations use the engine defaults. These values are identifiers, not a request to create or adopt another stack.

## Register and protect an agent

1. Register an external agent in the Console under a selected or newly created blueprint.
2. Complete the signed-in administrator's Registry confirmation when requested. Console sign-in does not replace tenant consent to the API's delegated Registry permissions.
3. Wait for the authoritative Active readback; save the one-time agent key securely.
4. On the agent's Data protection tab, review and confirm an existing compatible Purview policy for its exact individual identity.
5. Observe assignment status, then test normal allow and synthetic-sensitive block through the agent API. Check sibling scope independently. An assignment write alone is not evidence of blocking.

Prompt Shields is an independent per-agent choice. Connection diagnostics are under Settings. Classifiers, rules, exclusions and policy authoring remain in Purview.

## Rebuild after code changes

Run the [source checks](../../tests/README.md) first. From the repository root, using the existing generated environment file:

```powershell
docker build -t a365-gateway-api:dev -f src/Gateway.Api/Dockerfile .
docker build -t a365-gateway-worker:dev -f src/Gateway.Provisioning.Worker/Dockerfile .
docker build -t a365-gateway-console:dev web/console
docker compose --env-file deploy/runtime/.env.runtime -f deploy/runtime/docker-compose.yml -f deploy/runtime/docker-compose.apps.yml up -d --no-deps api worker console
.\gateway.cmd verify
```

Keep the Compose project name stable so existing database and object-store volumes remain attached. Bootstrap `plan` followed by `apply` is the full configuration/provisioning route; application-only rebuilds above do not provision tenant access or refresh the Windows management host. A changed source or configuration requires a newly accepted bootstrap plan.

## Diagnostics and API reference

The [local manual-refresh design](../spec/purview-connector-vnext.md) is the active
source contract. The Windows task starts one headless listener at the certificate-
owning user's logon; it has no recurring catalog trigger. **Connect** and **Manual sync** in Settings create durable operations. Page loads, status checks, idle
heartbeat, and ordinary API, Docker, or listener restart do not create provider
work; recovery may resume an already accepted, unexpired operation.

The last verified list stays cached in PostgreSQL without age expiry and remains
available for policy selection during sync or temporary management unavailability.
Use **Manual sync** when you want policy additions or changes from Purview. A failed
sync retains the saved list; applying an assignment still checks its selected
policy live before changing the exact agent target.

- `gateway.cmd status` reads saved checkpoints; `gateway.cmd verify` checks live API, database readiness and Console proxy/configuration.
- `gateway.cmd doctor` checks dependencies and Microsoft sessions. `gateway.cmd diagnose` produces sanitized diagnostics.
- Open [API reference](http://127.0.0.1:5081/docs) or the Console's API reference link. JSON and YAML contracts are available under `/openapi/v1.json` and `/openapi/v1.yaml`.
- Use [operator diagnostics](../../tools/scripts/README.md) for explicit DLP testing. A readiness error is not a DLP block.
- Check the Windows Purview listener task and its last heartbeat if management
  operations do not progress. The task starts at the certificate-owning user's
  logon; a browser sign-in does not replace that Windows account or repair its
  certificate access. After listener health is restored, use **Check status** to
  reconcile the same operation before starting another.
- A recent heartbeat proves listener liveness, not provider progress. If a refresh
  repeatedly reaches its deadline without a result, inspect the exact owned Windows
  task and its provider child before restarting that task. Reconcile pending
  assignments first; never repeat an uncertain policy write. After the original
  operation is terminal and listener health is restored, request one fresh refresh
  in the Console. Authenticated late completion is a timeout and retains the prior
  catalog; invalid authentication or binding is a separate repair condition.
- Use [operations](../../operations/README.md) for queue and downstream-delivery boundaries.

`/health` means the API process is responding. `/health/ready` checks database connectivity. Neither proves Purview enforcement, worker completion, or Microsoft destination visibility. Preserve correlation IDs and sanitized error codes for investigations; never include raw prompt content or credentials in support records.

After a Docker engine restart, PostgreSQL may briefly report that it is still
starting even though the application containers have also been restored. The API
and worker retry this transient startup state for a bounded period. The Console
proxy refreshes its Docker DNS lookup for `api` every five seconds, so it can show
a temporary HTTP 502 while the API is absent or starting but recovers without a
Console restart after the API becomes reachable. If a 502 persists after direct
`/health` is successful for longer than that interval, run `gateway.cmd verify`
and inspect recent Console and API logs. A running container without an API health
response is not a healthy gateway. Recreating `api` or `worker` with the existing
Compose project preserves named volumes and registration state.
