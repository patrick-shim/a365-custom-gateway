# Gateway runtime guide

## Installation

The terminal installer (`gateway.cmd init`) and React installer (`gateway.cmd gui`) use the same PowerShell engine, configuration schema, reviewed plan and verification. Follow [bootstrap](../../bootstrap/README.md) for tenant prerequisites and permissions. Both collect initial Content Safety and Purview settings; routine policy selection happens in the Console after setup.

The supported local topology is Docker Compose plus a Windows certificate-based Purview management host. Compose runs PostgreSQL, RabbitMQ, Vault, S3-compatible storage, the API, worker and Console. Default service credentials and Vault development mode make this a development configuration.

## Files that belong to the running installation

| Path | Purpose |
| --- | --- |
| `bootstrap/config.json` | Ignored, non-secret deployment settings |
| `.bootstrap/state/` | Owned-resource checkpoints |
| `.bootstrap/secrets/` | Credentials, transport key and blueprint-specific development credentials |
| `.bootstrap/purview-catalog/` | Signed policy snapshots |
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

- `gateway.cmd status` reads saved checkpoints; `gateway.cmd verify` checks live API, database readiness and Console proxy/configuration.
- `gateway.cmd doctor` checks dependencies and Microsoft sessions. `gateway.cmd diagnose` produces sanitized diagnostics.
- Open [API reference](http://127.0.0.1:5081/docs) or the Console's API reference link. JSON and YAML contracts are available under `/openapi/v1.json` and `/openapi/v1.yaml`.
- Use [operator diagnostics](../../tools/scripts/README.md) for explicit DLP testing. A readiness error is not a DLP block.
- Check the Windows catalog host if catalog snapshots become stale. Keep its bootstrap account and certificate available; a browser sign-in does not repair unattended certificate access.
- Use [operations](../../operations/README.md) for queue and downstream-delivery boundaries.

`/health` means the API process is responding. `/health/ready` checks database connectivity. Neither proves Purview enforcement, worker completion, or Microsoft destination visibility. Preserve correlation IDs and sanitized error codes for investigations; never include raw prompt content or credentials in support records.
