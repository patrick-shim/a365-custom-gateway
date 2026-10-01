# A365 Custom Gateway

Connect independently hosted agents to Microsoft Agent 365 identity,
observability and optional Prompt Shields and Microsoft Purview protection.
External agents keep their own hosting and model calls; the Gateway manages
registration, ingress credentials, protection checks and processing receipts.

## Build and install

Requirements: Git, PowerShell 7, Azure CLI and the .NET SDK selected by
[global.json](global.json). Windows Purview packaging additionally requires
the exact signed runtime versions in the [bootstrap guide](bootstrap/README.md).

```powershell
dotnet build .\src\A365Gateway.slnx --configuration Release
.\gateway.cmd setup
```

On macOS or Linux, run `./gateway setup`. The guided installer starts locally
and prepares a tenant/subscription-bound deployment plan before changing Azure.
For terminal operation:

```text
doctor -> init -> plan -> apply -> verify
                          resume after an eligible interruption
```

Registry provisioning is an explicitly acknowledged Development-only preview.
Staging and production admission remain closed. Deployment health does not
prove downstream telemetry delivery or policy enforcement.

## Connect an external agent

1. Sign in to the Admin UI and open **Getting started**.
2. Register an agent using a new or compatible existing identity blueprint.
3. Review independent telemetry and protection choices.
4. Save the API endpoint, external agent ID and one-time Gateway key securely.
5. Complete the signed-in administrator handoff for Agent 365 Registry creation.
6. Wait for the provisioning worker to verify the registration.
7. Evaluate prompts before calling the model, then submit the completed
   interaction with the same evaluation receipt.

Each registration has a distinct child identity and its own credential lifecycle.
Blueprints and their Purview policies can be shared. An Active registration is
not a claim that optional protection or telemetry delivery is ready.

The key is shown once. A lost key requires replacement, not another registration.
An uncertain create or provider response requires exact-ID readback, never a
second create. Removing a Gateway registration preserves linked Microsoft
identities and other external resources.

## Sample integration

The [sample client](src/ExternalAgent.Sample/Program.cs) requires HTTPS and reads
the Gateway key through a non-echoing prompt:

```powershell
dotnet run --project .\src\ExternalAgent.Sample -- `
  --api-base-url https://YOUR-GATEWAY-API/ `
  --external-agent-id YOUR-EXTERNAL-AGENT-ID `
  --tenant-user-object-id YOUR-USER-OBJECT-ID `
  --message "Hello through the Gateway"
```

It calls `POST /api/v1/prompts:evaluate` before its fixed-response model stub.
Replace the stub with your model callback while preserving that gate. A valid,
matching, unexpired allow receipt is required before generation and is consumed
once during ingestion.

The sample never repeats generation, requests replacement proof after generation
or retries uncertain ingestion automatically. HTTP 202 means accepted for
processing, not delivered. Inspect the receipt for the outcome. Keep secrets,
real prompt text and generated content out of command arguments and logs.

See the [API guide](docs/api/api-contract.md) and [OpenAPI](docs/api/openapi.yaml).

## Optional protection and telemetry

| Capability | Purpose |
|---|---|
| Agent 365 observability | Registration-scoped sanitized activity export. |
| Azure Monitor mirror | Independently selected sanitized monitoring telemetry. |
| Prompt Shields | Prompt attack evaluation before the external model call. |
| Microsoft Purview | Tenant connection, shared blueprint DLP and runtime evidence. |

Both protections Off is a complete core registration. Requested On defaults
are not silently rewritten when prerequisites are unavailable.

Purview setup has four steps: **Connect tenant**, **Set shared policy**,
**Test behavior**, and **Review agent choices**. The Windows companion loads
tenant classifier definitions; it does not create a policy or transfer the
administrator's sign-in session. Paste its complete fresh result into Settings;
the Gateway then verifies its own automation access.

A saved policy, simulation result or historical completed operation does not
prove current enforcement. Shared DLP uses the selected blueprint's Individual
scope; optional Know Your Data collection uses its separate fixed tenant-wide
Group. Runtime samples require explicit review and approval. Expired or changed
evidence invalidates current readiness.

## Repository layout

| Directory | Contents |
|---|---|
| [src](src) | Gateway services, Admin UI, provider adapters and sample client. |
| [tools](tools) | Setup application, database migrator and required installer helpers. |
| [bootstrap](bootstrap) | Canonical installer engine, configuration and foundation templates. |
| [infrastructure](infrastructure) | Workload templates and ordered SQL assets. |
| [operations](operations) | Supported maintenance and read-only deployment verification. |
| [docs](docs/README.md) | Product, architecture and API documentation. |

Start with the [bootstrap guide](bootstrap/README.md), consult
[operator workflows](operations/README.md) for an existing installation, and
use the [documentation hub](docs/README.md) for integration contracts.
