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

## Optional features

| Feature | Read |
|---|---|
| Agent 365 activity/OTel export | [Observability setup](operations/agent365-observability-setup.md) |
| Microsoft Purview runtime and policies | [Purview setup](operations/purview-setup-runbook.md) |
| Entra applications, app roles, and federation | [Entra setup](operations/entra-setup-runbook.md) |

Prompt Shields are configured by the bootstrap's `promptShield` section and then
selected per registration. Purview policy authoring is optional, and bootstrap
keeps its runtime adapter disabled until the post-bootstrap token-role and bounded
verdict checks pass. Its policy locations are not interchangeable: Know Your Data
uses the fixed tenant-wide enterprise-AI-apps `Group` location, while DLP uses each
selected blueprint application ID as an `Individual` location.

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
| Persistence and workflow design | [Data model](architecture/data-model.md) |
| Microsoft contract validation | [Microsoft capabilities](architecture/microsoft-capabilities.md) |
| Product intent | [Product brief](spec/product-brief.md) |
| Declarative Azure and SQL assets | [Infrastructure index](../infrastructure/README.md) |

## Engineering checkpoints

[Implementation status](implementation-status.md) records current source and test
truth. [Development deployment status](operations/development-deployment-status.md)
records authorized live evidence and safe resume context. Contributors should read
both before changing deployment or provisioning behavior; ordinary installers do
not need either file to follow the quickstart.

See [CONTRIBUTING](../CONTRIBUTING.md) for the development workflow and
[SECURITY](../SECURITY.md) for vulnerability reporting and secret-handling rules.
