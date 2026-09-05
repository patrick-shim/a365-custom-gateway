# A365 Custom Gateway documentation

Start with the task you are trying to complete. The root README and bootstrap guide
are the public installation path; engineering checkpoints and evidence records are
not setup instructions.

## Deploy and use

| Goal | Read |
|---|---|
| Clone, deploy, sign in, register, and send a sample | [Project quickstart](../README.md) |
| Configure, Plan, Apply, Resume, and Verify | [Bootstrap guide](../bootstrap/README.md) |
| Integrate an external agent with the API | [OpenAPI contract](api/openapi.yaml) |
| Understand Admin UI roles and routes | [Admin UI guide](agent-guides/admin-ui.md) |
| Understand Agent ID provisioning | [Provisioning guide](agent-guides/provisioning.md) |
| Review protection implementation and remaining gates | [Protection settings plan](architecture/protection-settings-plan.md) |

## Optional features

| Feature | Read |
|---|---|
| Agent 365 activity/OTel export | [Observability setup](operations/agent365-observability-setup.md) |
| Microsoft Purview runtime and policies | [Purview setup](operations/purview-setup-runbook.md) |
| Entra applications, app roles, and federation | [Entra setup](operations/entra-setup-runbook.md) |

The source separates capability installation from ongoing protection governance.
Bootstrap prepares Azure AI Content Safety and Purview prerequisites.
Role-aware Gateway Settings owns Prompt Shields defaults and per-agent use, plus
Purview tenant connection, SIT selection, KYD, blueprint DLP profiles, readiness,
and ongoing changes. Final backend acceptance reopened the source candidate for
identity correctness, exact capability/runtime binding, cancellation cleanup, and
truthful existing-policy updates. Prior final gates are invalidated. This
implementation is not deployed, and its live E2E is postponed. Readback is not
token-role propagation or live verdict proof.
Purview locations remain independent: Know Your Data uses the fixed tenant-wide
enterprise-AI-apps `Group`, while DLP uses each selected blueprint application ID
as an `Individual`.

## Operate and recover

| Goal | Read |
|---|---|
| Operate an existing deployment | [Operations index](../operations/README.md) |
| Back up or recover data and configuration | [Backup and recovery](operations/backup-recovery.md) |
| Rotate credentials and certificates | [Credential rotation](operations/credential-rotation.md) |
| Upgrade safely | [Upgrade strategy](operations/upgrade-strategy.md) |
| Respond to an incident | [Incident response](operations/incident-response.md) |

## Design and implementation

| Topic | Read |
|---|---|
| System architecture | [System architecture](architecture/system-architecture.md) |
| Protection capability and Settings implementation | [Protection settings plan](architecture/protection-settings-plan.md) |
| Persistence and workflow design | [Data model](architecture/data-model.md) |
| Microsoft contract validation | [Microsoft capabilities](architecture/microsoft-capabilities.md) |
| Product intent | [Product brief](spec/product-brief.md) |
| Declarative Azure and SQL assets | [Infrastructure index](../infrastructure/README.md) |

## Engineering checkpoints

| Purpose | Read |
|---|---|
| Continue after a Git transfer | [Continuation checkpoint](agent-continuation.md) |
| Read current source and test truth | [Implementation status](implementation-status.md) |
| Read live evidence and operator boundaries | [Deployment status](operations/development-deployment-status.md) |
| Understand durable historical corrections | [Project history](history/README.md) |

Contributors should read the continuation and both current status files before
changing deployment or provisioning behavior. Project history is context, not a
current checkpoint. Ordinary installers do not need these engineering records to
follow the quickstart.
