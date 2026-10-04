# Infrastructure assets

Gateway hosting uses [runtime Compose](../deploy/runtime/README.md): PostgreSQL,
RabbitMQ, Vault/OpenBao, S3-compatible storage and OCI application containers.
Microsoft Entra, Graph, Agent 365, Purview and Prompt Shields remain product services.

## Active Bicep templates

| Template | Purpose |
| --- | --- |
| [runtime-content-safety.bicep](bicep/runtime-content-safety.bicep) | Optional Prompt Shields resource provisioning during runtime bootstrap |
| [content-safety.bicep](bicep/modules/content-safety.bicep) | Content Safety account module used by that template |

## Database assets

PostgreSQL starts from the current EF model through
`src/Gateway.Infrastructure/Persistence/RuntimeSchemaInitializer.cs` under an
advisory lock.
The [runtime integration tests](../tests/README.md) validate a fresh schema,
constraints, coordination and orphan rejection. No old-schema adoption is supported.
