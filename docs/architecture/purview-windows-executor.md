# Purview Windows execution boundary

Status: implementation and offline review in progress, 2026-09-06. This document
does not establish deployment, provider connectivity or DLP readiness. Follow the
[current continuation](../agent-continuation.md) for the exact first unfinished
action. The reviewed host, worker transport, publisher, package inspector, Bicep
and tests are now in canonical source for model handoff. They are not deployed;
the integration and acceptance steps below remain unfinished.

Microsoft's [Exchange Online PowerShell module documentation](https://learn.microsoft.com/en-us/powershell/exchange/exchange-online-powershell-v2?view=exchange-ps)
does not support Security & Compliance PowerShell on PowerShell 7 for Linux or
macOS. Both the connection verifier and Settings policy provider use
`Connect-IPPSSession`. Installing the module in the Linux worker cannot prove that
either provider works.

## Responsibility and identity

The Linux worker keeps SQL, outbox, both dedicated queues, the seven registration
stages, its Graph allowlist and its runtime managed identity. A private Windows
App Service hosts only these six fixed provider operations:

- verify the Purview automation connection;
- read or create fixed-scope Know Your Data policy;
- read a blueprint DLP profile;
- create its exact DLP policy; and
- create its exact DLP rule.

No public generic PowerShell, script, command, Graph proxy or remote-reset endpoint
is exposed. The application is self-contained .NET 10 for Windows x64, packaged
with Microsoft-signed PowerShell 7.6.5 and ExchangeOnlineManagement 3.10.1. Startup
verifies the complete runtime file manifest and imports the pinned module before
serving requests. Startup does not connect to the compliance provider.

A dedicated single-tenant API application publishes only the application role
`Purview.Executor.Invoke`. Only the exact Linux worker system managed identity
receives it. App Service authentication and application authorization independently
check the caller. Application checks include signature, issuer, audience, tenant,
principal, client application, role, lifetime and absence of delegated `scp`.
No client secret or delegated sign-in fallback is used.

The executor system identity reads only the exact certificate secret, reads its
package container and writes its separate durable claim container. It receives no
SQL, Service Bus, Graph or Registry permissions. Its identity is distinct from the
Gateway API, worker and Purview runtime managed identities. Certificate bytes stay
inside the Windows provider and are never returned through the transport.

## Private package delivery

App Service uses a dedicated VNet integration subnet and a private endpoint with
private DNS for both application and SCM names. Public network access and basic
publishing credentials remain disabled. The ZIP is addressed by SHA256 in private
Blob Storage and loaded with the App Service system managed identity; no SAS or
publishing credential is introduced.

A manual Container Apps job publishes the fixed ZIP embedded in its immutable
publisher image. It has one replica, no automatic retries, a bounded deadline and
only package-container Blob Data Contributor permission. That role includes delete
permission; create-only behavior is enforced by the publisher's conditional write.
The job has no certificate, claims-container, SQL, queue or Graph authority.

Before image construction, the package inspector verifies the source-bound receipt,
full ZIP digest, exact runtime manifest and every file hash. Counted reads enforce
actual expanded sizes, including corrupt ZIP size metadata. Windows path rules
reject traversal, reserved names, aliases, case collisions and file/directory
conflicts. The build context includes only allowlisted publisher sources, public
build settings and the independently hashed ZIP.
The packaging script itself participates in the deployment source fingerprint;
changing its bytes invalidates package source identity. Two fixture regressions
and independent review verify this boundary; unrelated operator scripts stay excluded.

The publisher requires the expected private storage address before obtaining its
system-identity credential. Deployment orchestration must independently verify the
owned network, storage public access, private endpoint and DNS; the process DNS
check is not socket pinning. Local payload hash and length are checked before any
storage access. One upload uses `If-None-Match: *`; a lost response allows exact
readback only. Independent readback uses the observed ETag and hashes all bytes.
Existing different content is never overwritten or deleted.

## Request and mutation contract

Both sides independently load the same execution binding from deployed
configuration. It binds deployment ownership, tenant, original bootstrap source,
new execution source, package digest, automation application and principal, exact
vault and certificate, Gateway API and worker principals, runtime identity, and
executor application and principal. Requests cannot choose this authority.

Requests also bind operation ID, one fixed command and a short expiration. For
mutations, a conditional Blob claim is persisted before provider invocation. Its
key binds deployment, tenant, operation and provider command; its canonical input
hash excludes the transport expiration. Different content conflicts. A duplicate
Started or unknown claim never repeats the provider mutation. A completed claim
replays only the bounded typed result. Provider read operations remain fresh.

One 195-second server deadline covers credential access, provider execution,
termination and durable result storage. The client has a separate 215-second
deadline and no transport retry. Owned child termination is bounded and independently
checked. If exit cannot be proved, the host rejects later mutations until an owned
recycle. An HTTP timeout does not prove the provider mutation did not happen.

## Remaining integration and acceptance

The host/client boundary has passed independent source review and 66 focused tests.
The publisher boundary has passed independent source review and 49 tests. The
package inspector has 29 passing tests and completed independent review. These are
offline source results. A built package exists, but automatic tool policy blocked
its local host startup check. No Windows runtime or provider success is claimed.

The first deployment still needs these concrete pieces:

1. A preserved, reviewed plan and separate receipt binding the completed bootstrap
   plan, configuration, original source, exact API/worker/runtime identity and SQL
   evidence to the new executor source and package.
2. Durable creation and exact readback of the dedicated API application, service
   principal and worker role assignment, without ambiguous adoption or repeated
   mutations after unknown outcomes.
3. Source-bound publisher image construction, private network and identity
   readback, exact manual job execution and independent package verification.
4. Private Windows host deployment and runtime attestation, followed by an exact
   worker image/configuration upgrade that preserves its original identities,
   queues, SQL markers and bootstrap capability binding.
5. Verification that understands the separate completed upgrade receipt, plus
   fresh-bootstrap integration when Purview prerequisites are selected. A completed
   deployment's original accepted plan and stage evidence must not be rewritten.
6. Full source/export gates, independent integration review, authorized Windows
   runtime/provider proof, and Settings connection, SIT, KYD and DLP acceptance.

The operator stopped live delivery with a partial certificate after Entra rejected
public-key publication. Source was promoted for handoff only. The partial recovery
needs a separate exact repair; promotion does not extend its source authorization.
Complete core bootstrap independently before any live Windows upgrade. DLP remains fail closed until capability,
policy readback, propagation, runtime token roles and exact allow/block evidence
are independently verified. The [Purview runbook](../operations/purview-setup-runbook.md)
owns those readiness rules. Core registration remains independent of optional DLP.
