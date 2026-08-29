# Infrastructure assets

This directory contains declarative assets shared by the clean-subscription
bootstrap and existing-environment operations. It contains no orchestration entry
point and no secret values.

- `bicep/` defines the reviewed Azure workload, Admin UI, monitoring, optional
  managed-identity Azure AI Content Safety Prompt Shields, and supporting modules.
  Environment parameter files live beside the templates they configure.
- `sql/` contains the ordered, forward-only database phases used by
  `tools/Gateway.DatabaseMigrator`. Apply them only through the bootstrap or the
  reviewed upgrade and recovery runbooks.

Prompt protection requires the additive
`sql/20260829_prompt_protection.sql` phase before any registration enables Prompt
Shields or the new prompt-only Purview receipt contract. The Content Safety module
disables local authentication and assigns the API managed identity Cognitive
Services User; it never provisions or stores an account key.

Use [`../bootstrap/README.md`](../bootstrap/README.md) to create a Gateway from a
fresh subscription. Use [`../operations/README.md`](../operations/README.md) for a
reviewed update or verification of an existing environment. A successful template
build or local migration test is not evidence that Azure or SQL was changed.
