# Purview Windows execution boundary

This guide describes the retained executor, worker transport and packaging source.
Project completion belongs only in [MILESTONES.md](../../MILESTONES.md); see
[project state](../project-state.md) for current environment and tooling context.
No current Windows deployment, provider connection or DLP readiness is asserted.

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

## Private package delivery

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
verification boundaries. The milestone plan tracks their implementation and
acceptance. Missing tool/test projects must be restored before claiming
reproducible packaging or release validation.

The [protection architecture](protection-settings-plan.md) explains reviewed
registration configuration, multiple SITs and modes, shared scope, approved
runtime samples and fail-closed enforcement.
