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

The Purview prerequisite correction adds an exact-plan recovery with independent
readback and at most one attempt per missing prerequisite. Its Resume path preserves
completed deployment evidence and restores the corrected immutable tooling source
before each stage. Current acceptance and live results remain in the checkpoints;
this history does not claim that the recovery or Windows executor has been deployed.

All model changes use the shared
[handoff protocol](../agent-guides/model-handoff.md). Git history records completed
source commits; ignored local evidence and drafts do not become portable by being
mentioned in a commit message or chat.

Exact historical resource identifiers, transient revisions, repeated test totals,
and terminal command transcripts are intentionally omitted from the public path.
Restricted operational evidence belongs in the deployment/incident evidence store.
The two current status files above remain authoritative for source and live truth.

The latest handoff records a stopped live recovery: both grants verified, certificate
storage succeeded, Entra public-key publication failed. Windows implementation was
promoted into canonical main for continuation; deployment integration and full E2E
remain open. The current checkpoints supersede earlier pending-Plan descriptions.
