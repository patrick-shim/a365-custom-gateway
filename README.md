# A365 Custom Gateway

A365 Custom Gateway connects existing external agents to Microsoft Agent 365.
Administrators register agents against reusable Microsoft Entra Agent Identity
blueprints, manage their Gateway access, choose telemetry destinations and
configure optional Prompt Shields and Microsoft Purview protection. External
agents use a Gateway external ID and ingress key; they do not receive the
Gateway's Microsoft credentials.

The retained application is the working baseline. The project is improving its
user journeys, wording, selected features and repeatable testing. Supporting tools,
tests and related Azure resources were deliberately deleted. Old deployment
checkpoints and repair targets do not describe a current installation.

**[MILESTONES.md](MILESTONES.md) is the sole completion and acceptance record.**
Read [AGENTS.md](AGENTS.md) for project instructions and
[project state](docs/project-state.md) for continuation context.

## Main user journey

1. Deploy through the canonical installer once its missing tooling has been
   restored and validated.
2. Sign in to the Admin UI with the appropriate Gateway role.
3. Register an external agent using a new or existing compatible blueprint,
   selecting telemetry and protection settings.
4. Store the one-time Gateway ingress key and external agent ID in the external
   agent's secret/configuration store.
5. Complete the signed-in administrator handoff for Agent 365 Registry creation.
   The provisioning worker then verifies the connection.
6. Evaluate each prompt before generation, then submit the resulting activity
   and interaction with the evaluation receipt.
7. Inspect processing status, protection evidence and operational history.

Each registration has a distinct child Agent Identity. Multiple registrations may
share a blueprint and its Purview policy. Registration status `Active` does not
by itself prove that a selected protection or telemetry destination is ready.
Deleting a registration removes it from Gateway use; the current worker preserves
Microsoft identities and other external resources.

## Installation status

The intended entry point remains `./gateway setup` on macOS/Linux or
`.\gateway.cmd setup` on Windows. **The complete installation path is not yet
revalidated runnable after the reset.** The retained launchers and solution
reference these absent projects:

| Missing source | Role in the intended workflow |
|---|---|
| `tools/Gateway.Setup` | Temporary local setup UI |
| `tools/Gateway.DatabaseMigrator` | Database initialization and reviewed migration tooling |
| `tools/Gateway.LiveVerification` | Independent live verification tooling |
| `tests/` | Former automated test projects |

Generated `bin/` and `obj/` files do not replace those sources or establish a
clean build. M1 covers the minimum tooling and reproducible behavioral baseline;
M5 and M6 cover release and hosted acceptance. See the
[bootstrap guide](bootstrap/README.md) for the retained installer contract.

The retained Registry provisioning path is a Development-only preview; production
admission remains closed. Pinned build inputs include [global.json](global.json),
[Directory.Build.props](Directory.Build.props) and [nuget.config](nuget.config).
Purview executor packaging additionally requires the Windows runtime versions
described in the bootstrap guide.

## External-agent integration

The retained [sample client](src/ExternalAgent.Sample/Program.cs) demonstrates the
flow. After a verified deployment, use the API URL and external ID from the Admin
UI. It reads the Gateway key through a non-echoing prompt.

```bash
dotnet run --project src/ExternalAgent.Sample -- \
  --api-base-url https://YOUR-GATEWAY-API/ \
  --external-agent-id YOUR-EXTERNAL-AGENT-ID \
  --tenant-user-object-id YOUR-USER-OBJECT-ID \
  --message "Hello through the Gateway"
```

The sample calls `POST /api/v1/prompts:evaluate` before its fixed-response stub.
Generation requires an allowed response with a valid, unexpired evaluation
receipt. Replace the stub callback with the model call while keeping that gate.
The completed interaction carries the same receipt as
`promptEvaluationReceiptId`; the server checks its prompt, identity, expiry,
one-time consumption and protection context again.

A protection change can invalidate a receipt during generation. The sample does
not automatically repeat generation, obtain replacement proof after generation,
or retry uncertain ingestion. HTTP 202 means accepted for processing; consult the
receipt for its outcome. Use synthetic command-line message text and keep keys,
tokens and generated content out of command arguments and logs. See the
[API guide](docs/api/api-contract.md) and [OpenAPI](docs/api/openapi.yaml).

## Telemetry and protection

| Capability | Product behavior |
|---|---|
| Agent 365 observability | Registration-scoped sanitized activity export, selected independently from Azure Monitor. |
| Azure Monitor mirror | Sanitized telemetry through the Gateway monitoring pipeline. |
| Prompt Shields | Per-agent prompt attack evaluation through Azure AI Content Safety. |
| Microsoft Purview | Tenant collection settings and shared blueprint DLP configuration, with separate runtime evidence. |

Deployment capability, administrator configuration and effective runtime behavior
are separate facts. Prompt Shields uses a verified Content Safety/managed-identity
binding. Purview distinguishes tenant connection, classifier inventory, policy
readback, propagation, token roles and runtime results. Simulation or accepted
audit submission must not be shown as proven enforcement.

Purview Know Your Data uses the fixed tenant-wide enterprise-AI-apps `Group`
location. DLP uses the selected blueprint application ID as an `Individual`
location. Both use the Application enforcement plane. Changes to a shared profile
must make their affected registrations clear.

## Architecture and operation

The Blazor Admin UI calls the Gateway API, which enforces authorization and stores
durable work in SQL. An outbox sends work to Service Bus for the provisioning and
protection workers. Purview administration uses a separate Windows executor;
runtime prompt evaluation uses the configured provider identities. These
boundaries support recovery without assuming exactly-once delivery.

- [Documentation hub](docs/README.md)
- [Product brief](docs/spec/product-brief.md)
- [System architecture](docs/architecture/system-architecture.md)
- [Protection design](docs/architecture/protection-settings-plan.md)
- [Bootstrap and configuration](bootstrap/README.md)
- [Infrastructure assets](infrastructure/README.md)
- [Operator workflows](operations/README.md)

Guides explain behavior. Only the milestone checklist records accepted completion.
