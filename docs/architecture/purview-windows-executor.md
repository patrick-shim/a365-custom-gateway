# Purview Windows execution boundary

This guide describes the executor, worker transport and packaging source.
Windows/package qualification is distinct from a compliance provider connection
or DLP readiness. A private authenticated health response
must match the expected source and package; bootstrap's Installed status alone
does not establish that runtime result or policy enforcement.

## Responsibilities

The Linux worker owns SQL, outbox, dedicated queues and durable protection
operations. Certificate-backed Security & Compliance PowerShell runs through a
private Windows App Service. The fixed command set is:

| Command | Purpose |
|---|---|
| VerifyConnection | Verify the prepared Purview automation connection |
| ReadKnowYourData | Read fixed-scope KYD configuration |
| CreateKnowYourData | Apply the reviewed fixed-scope KYD operation |
| ReadDlpProfile | Read the exact blueprint policy/rule |
| CreateDlpPolicy | Apply the reviewed policy operation |
| CreateDlpRule | Apply the reviewed rule operation |

Requests expose no generic command, script, Graph proxy or remote-reset interface.
The command names and request binding are defined in
[PurviewExecutorContracts.cs](../../src/Gateway.Purview/PurviewExecutorContracts.cs).

The Windows boundary follows the repository's supported execution design for
Connect-IPPSSession. Installing the module in the Linux worker is not its
substitute. Recheck the official
[module support documentation](https://learn.microsoft.com/en-us/powershell/exchange/exchange-online-powershell-v2?view=exchange-ps)
when validating a deployment.

## Runtime and console-free child

The package targets self-contained .NET 10 for Windows x64, with pinned PowerShell
7.6.5 and ExchangeOnlineManagement 3.10.1. Startup verifies the runtime manifest and
imports the pinned module before serving requests; it does not connect to the
compliance provider.

The web host starts a dedicated Gateway.Purview.PowerShellHost.exe process. That
child hosts the packaged System.Management.Automation engine through PSHost and
runspace APIs without a raw console UI. It accepts only a fixed probe or approved
script/parameter combinations and rejects arbitrary commands or interactive
prompts.

The child independently checks the manifest before loading the engine. Canonical
packaging compiles against the signed packaged engine through
PurviewPowerShellReferencePath. Ordinary builds use the exact compile-only 7.6.5
reference; that reference is not a replacement runtime. Approved reference
assemblies used by Add-Type are included in the same hash inventory.

The certificate password uses stdin. Typed result envelopes use stdout.
Unexpected pipeline-object output and unsafe error details are rejected. The
parent owns cancellation and whole-process-tree termination. Local process
behavior alone does not establish cloud runtime or provider connectivity.

Each settings invocation imports only its required Security & Compliance
commands and reads one fresh SIT catalog for all of that invocation's primary
and multi-SIT validation. The catalog is not reused across invocations. Authority
is checked before connecting and again immediately before every New/Set call,
including after reading an existing update target. This reduces avoidable
provider work without extending the accepted deadline or inventory lifetime.
The native child remains bounded to 180 seconds.

Failed reads preserve the safe `PURVIEW_INVENTORY_STALE` or proven transient
`PURVIEW_SETTINGS_READ_TIMEOUT` classification when available; other read
failures remain unavailable. These classifications do not authorize mutation
replay. A Started mutation claim with an unknown result still requires exact
readback, even if the same provider work would now time out or its inventory
has expired.

## Caller and certificate authority

A dedicated single-tenant API application exposes Purview.Executor.Invoke to the
exact worker system managed identity. App Service authentication and application
authorization independently check the caller. The application checks signature,
issuer, audience, tenant, principal, client application, role and lifetime, and
rejects delegated scope tokens.

The executor identity is distinct from API, worker and Purview runtime identities.
It reads the exact certificate secret and package container, and writes its
dedicated durable claim container. It has no SQL, Service Bus, Graph or Registry
authority. Certificate bytes stay within the Windows provider.

The Windows host configuration requires WEBSITE_LOAD_USER_PROFILE=1 and verifies
that setting in readback. It supports private-certificate loading; it does not
establish tenant connection or policy readiness.

The private worker health response can expose a bounded recent failure receipt:
operation ID, timestamp, fixed stage/category and numeric child/provider stage.
It excludes exception messages, provider bodies and secret material. A diagnostic
receipt is not connection or enforcement proof.

### The automation application's provider reference

An Entra enterprise application and its Security & Compliance service-principal
reference are separate objects. The reference uses the existing application's
AppId and the enterprise application's ObjectId, not the app-registration
object ID. `VerifyConnection` deliberately requires exactly that pair through
`Get-ServicePrincipal` before resolving the administrator and reading the
classifier catalog. Successful certificate sign-in alone cannot skip this check.

The retained bootstrap creates the Entra/certificate/executor prerequisites; it
does not register that separate provider reference. The Windows companion reads
administrator-bound catalog facts and also does not create the reference, transfer
its sign-in session or grant the automation app permissions. Before the first
tenant connection, an authorized administrator must verify this prerequisite.
See the [bounded operator procedure](../../operations/README.md#purview-automation-reference-prerequisite).

If an exact read proves the reference absent, Microsoft's
[New-ServicePrincipal](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-serviceprincipal?view=exchange-ps)
registers the existing identity in Security & Compliance. This is not a new
Entra identity or a role/policy grant. A mismatch or unknown create outcome
requires investigation/readback, never another create. Verify the Gateway's own
app access separately after registration; neither the reference nor a human
catalog read proves DLP configuration or enforcement.

## Private package delivery

Fresh installations select one Windows Basic B1 worker. That choice supports the
required private endpoint and VNet integration; allocation and private runtime
health must still be checked independently. Existing installations preserve
their original hosting receipt. The
[explicit maintenance acknowledgment](../../operations/gateway-upgrade.md#source-only-maintenance-of-an-installed-full-deployment)
can verify an approved, already-existing B1/B2 change without resizing or
rewriting that history.

The source provisions dedicated VNet integration, private endpoint and DNS for
application/SCM names. Public network access and basic publishing credentials are
disabled. App Service loads a SHA256-addressed ZIP from private Blob Storage using
its system identity.

A manual Container Apps job publishes the fixed ZIP embedded in an immutable
publisher image. It has one replica, bounded duration, no automatic retries and
package-container Blob Data Contributor authority only. That role includes
deletion capability; the publisher implements create-only behavior with a
conditional write.

The package inspector verifies the source receipt, archive digest, runtime
manifest and every file hash. Counted reads bound actual expanded size. Windows
path validation rejects traversal, reserved names, aliases, collisions and
file/directory conflicts. The build context contains allowlisted publisher
sources, public settings and the inspected ZIP.
The publisher Dockerfile copies the reviewed SDK, version and NuGet inputs into
the build root before restore and explicitly uses the repository feed configuration.
Including these files in the build context alone does not make the SDK or
MSBuild consume them; an omitted version input would publish default metadata
instead of the repository release version.

The publisher checks the expected private storage address before obtaining
credentials, validates the local payload, and writes with If-None-Match: *.
A lost response allows exact readback only. Independent readback verifies the
observed ETag and all content bytes. Existing different content is not overwritten
or deleted.

## Request binding and recovery

Worker and executor independently load an execution binding containing:

- deployment ownership, tenant and bootstrap/execution source fingerprints;
- package digest and exact automation application/principal;
- vault, certificate and secret URI;
- API, worker and runtime identity bindings;
- executor application/principal and caller application.

A request cannot choose replacement authority. It adds only the operation ID,
fixed command, bounded input and short expiration.

Before a mutation, the executor conditionally writes a Blob claim keyed by
deployment, tenant, operation and command. The canonical input hash excludes
transport expiry. Different content conflicts. A duplicate Started or unknown
claim does not repeat the mutation; a completed claim replays only its bounded
typed result. Read operations remain fresh.

The server uses one 195-second deadline covering credential access, provider work,
termination and durable result storage. The client deadline is 215 seconds, with
no transport retry. If child exit cannot be proved, later mutations are fenced
until an owned recycle. Timeout does not prove that a mutation did not occur.

## Lifecycle and verification limits

Fresh bootstrap contains executor integration when Purview prerequisites are
selected. Retained [upgrade operations](../../operations/gateway-upgrade.md)
provide separately bound existing-installation workflows. Original accepted
bootstrap state must not be rewritten as evidence for changed source.

Package integrity, host startup, worker authentication, compliance authorization,
tenant inventory, exact policy readback and runtime sample behavior are independent
verification boundaries. Local compilation does not replace a
fresh signed runtime package or frozen-candidate release validation.

Package qualification verifies the exact ZIP receipt and source fingerprint,
the packaged native probe, rejection of altered manifests and unapproved
commands, and the executor's unauthenticated HTTP boundary. None of those checks
proves provider authorization. The build prerequisite verifies that the selected
PowerShell process is X64, not merely a 64-bit architecture.

The [protection architecture](protection-settings-plan.md) explains reviewed
registration configuration, multiple SITs and modes, shared scope, approved
runtime samples and fail-closed enforcement.
