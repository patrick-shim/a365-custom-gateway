# Runtime Purview catalog and assignment host

Bootstrap configures a dedicated Entra application, a certificate in the Windows
executor account's certificate store, and the required Purview management role.
It verifies certificate authentication and starts `Gateway.Purview.CatalogHost`.
The Console does not perform initial connection setup or create DLP rules.

The host invokes `Read-Catalog.ps1` with ExchangeOnlineManagement 3.10.1. That
script reads existing policies and rules. Each successful catalog is signed;
the API verifies the pinned certificate, tenant and freshness before accepting it.
The API receives the catalog directory as a read-only mount.

An administrator reviews an existing compatible policy for an exact individual
agent identity. Confirmation creates a durable PostgreSQL assignment. The API
checks runtime access and writes an authenticated, expiring assignment request.
The host verifies the request and applies only the reviewed target delta through
`Add-PurviewIndividualTarget.ps1`. Existing targets and exclusions are preserved.
It reads the scope back and publishes an authenticated result tied to the request.
The API reconciles that result into the assignment row.

The host polls between catalog reads; each provider invocation has a six-minute
deadline. Assignment confirmation has a fifteen-minute window. Unknown outcomes
remain unconfirmed; a timeout does not authorize an automatic second mutation.
The Console polls status, shows an animated wait and elapsed time, and stops
the animation on failure, stale/unavailable status or confirmation timeout.

Assignment does not prove enforcement. The gateway calls Graph protection-scope
and `processContent` APIs under the selected agent identity. Normal allow,
synthetic-sensitive block and same-blueprint sibling evidence are separate checks.

The local host is currently a background Windows process, not a reboot-persistent
service. Its certificate account and process lifetime are operational requirements.
There is no Azure-hosted executor, Key Vault certificate download, package
publisher, custom embedded PowerShell host or Azure storage journal.
