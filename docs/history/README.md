# Project history

Git history preserves the detailed development chronology. Current documentation
describes the product as it works now; readers do not need the implementation
sequence to install, operate, or extend it.

Do not reconstruct current work, safety boundaries, or deployment state from this
chronology or from old troubleshooting records. Use the tracked
[agent continuation checkpoint](../agent-continuation.md), current
[implementation status](../implementation-status.md), and current
[development deployment status](../operations/development-deployment-status.md).

Durable corrections incorporated into the current design include:

- private-network execution for Entra-only Azure SQL initialization;
- a dedicated Container Registry pull identity;
- exact Azure provider-shape validation before and after deployment;
- database initialization only when zero user tables exist;
- creator-bound planned Registry IDs and one-POST/exact-GET recovery;
- a dedicated v3 queue and worker contract;
- user-only Registry completion through delegated OBO;
- single-use prompt-evaluation receipts;
- separate tenant-wide Know Your Data Group and blueprint-specific DLP Individual
  policy scopes;
- optional protection readiness independent from core registration admission;
- concise public setup through the root `gateway` launcher.

Exact historical resource identifiers, transient revisions, repeated test totals,
and terminal command transcripts are intentionally omitted from the public path.
Restricted operational evidence belongs in the deployment/incident evidence store.
The two current status files above remain authoritative for source and live truth.
