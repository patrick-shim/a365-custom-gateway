# Runtime Purview connector and assignment host

Bootstrap configures a dedicated Entra application, a certificate in the Windows
executor account's certificate store, and the required Purview management role.
It verifies certificate authentication and installs
`Gateway.Purview.CatalogHost` as a headless listener. The Console does not collect
the management credential or create DLP policies, rules, classifiers, or SITs.

## Lifecycle

Task Scheduler starts one listener when the certificate-owning user signs in. The
task has no repeating trigger and runs with no execution-time limit; Task
Scheduler restarts a failed listener up to three times. The listener publishes an
authenticated heartbeat while idle and polls only local connector and assignment
directories. Idle polling, heartbeat, elapsed time, page loads, GET requests, and
ordinary API, Docker, or listener restarts do not create provider work. Restart
recovery may resume only an already accepted, unexpired operation.

The listener emits a domain-authenticated heartbeat every five seconds. Outside
an active connector operation, six missed heartbeats make local management
readiness stale: a connection with an accepted snapshot becomes `Degraded` and
retains that snapshot; without one it becomes `Disconnected`. A later authenticated
heartbeat restores only this liveness-induced state and performs no provider read.

This local profile still requires that Windows user to sign in after a host
restart. There is no pre-logon Windows service, Azure-hosted executor, Key Vault
certificate download, package publisher, embedded PowerShell host, or Azure
storage journal. The container-capable server/cloud profile is M6 and remains on
hold.

During bootstrap, access verification already reads one complete catalog.
Bootstrap passes that exact verified result to the host's bounded
`--publish-bootstrap` mode, which validates and signs it without a second provider
read. The API may import this signed bootstrap file exactly once when the connector
tables are empty. Thereafter the file is compatibility/migration material;
PostgreSQL is the catalog authority.

## Manual connector protocol

A Gateway Administrator explicitly requests Connect or Policy Refresh. The API
first stores the operation in PostgreSQL, then the background dispatcher writes a
domain-separated HMAC-authenticated command atomically. The command binds:

Submission and dispatcher state transitions share a tenant-scoped serialization
boundary. A transient database serialization or deadlock conflict before commit is
retried within a bounded request using a fresh transaction and state read. The
dispatcher cannot publish a command until the operation commits, so this internal
retry cannot duplicate provider work.

- tenant and stable connector instance;
- operation ID, action, and monotonic generation;
- canonical request hash;
- issue and expiry timestamps.

The listener accepts only the expected typed actions (`VerifyConnection` and
`RefreshCatalog`); no request supplies a script or shell command. It verifies the
MAC and every binding before starting a bounded Security & Compliance PowerShell
child. Provider work is capped at six minutes and cannot outlive the operation's
ten-minute deadline. The listener kills the child process tree when cancelled.

The result repeats the command bindings and contains either a complete catalog
plus canonical hash or a sanitized failure code. The listener authenticates and
writes it atomically, advances an authenticated generation checkpoint, and
updates heartbeat evidence. The API verifies the result and deadline before
accepting it into PostgreSQL. A stale generation, replay, wrong tenant or
connector, mismatched request, malformed catalog, or invalid MAC cannot replace
accepted state.

The dispatcher republishes the same authenticated command after the crash window
between committing `Running` and writing the file. Publication is idempotent and
an existing file must exactly match durable state. After PostgreSQL has accepted a
terminal result and the authenticated host checkpoint covers its generation, the
dispatcher verifies both files and removes the transport copies. Durable operation
and catalog evidence remain in PostgreSQL.

## Accepted catalog authority

`PurviewConnectorStates`, `PurviewConnectorOperations`, and
`PurviewCatalogSnapshots` are authoritative after migration. Policy listing and
assignment review deserialize the latest accepted snapshot, recheck tenant,
connector/operation identity, generation, canonical digest, schema, completeness,
unique IDs, and policy revisions, and never read a newly written transport result
directly.

A failed refresh preserves the last accepted snapshot. Connection state becomes
`Degraded` when that snapshot exists or `Disconnected` when none exists. Catalog
age is shown to administrators; a new assignment review or confirmation requires
a catalog retrieved within thirty days. An existing durable confirmed
assignment does not expire merely because the display inventory becomes old.
The longer accepted-snapshot reuse window is separate from the connector protocol:
a newly completed provider operation must return catalog evidence retrieved within
fifteen minutes of its completion and bound to that exact command.

Successful refresh acceptance reconciles the latest confirmed assignment for each
agent and policy. A removed policy, changed canonical revision, missing exact
individual target, or incompatible policy changes that assignment to
`NeedsAttention`, advances only the affected agent's protection revision, and
records an audit event. Unrelated catalog changes do not invalidate all agents.

## Assignment protocol

An administrator reviews an existing compatible policy from the accepted catalog
for one exact individual agent identity. Confirmation creates durable PostgreSQL
assignment state and an authenticated, expiring assignment request. The host
verifies the request and uses `Add-PurviewIndividualTarget.ps1` to read the selected
policy live, reject revision drift or conflicting/narrow scope, apply only the
reviewed target addition, preserve all unrelated targets and exclusions, and read
the result back. Unknown mutation outcomes remain unconfirmed and never authorize
an automatic duplicate write.

Assignment does not prove enforcement. The Gateway separately calls Graph
protection-scope and `processContent` APIs under the individual agent identity.
Normal allow, synthetic-sensitive block, and same-blueprint sibling evidence are
separate, explicitly gated live checks.

The [manual-refresh record](../spec/purview-connector-vnext.md) contains the full
state, migration, and test matrix.
