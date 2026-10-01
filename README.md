# A365 Custom Gateway

A365 Custom Gateway connects existing external agents to Microsoft Agent 365.
Administrators register agents against reusable Microsoft Entra Agent Identity
blueprints, manage their Gateway access, choose telemetry destinations and
configure optional Prompt Shields and Microsoft Purview protection. External
agents use a Gateway external ID and ingress key; they do not receive the
Gateway's Microsoft credentials.

The retained application is the working baseline. The project is improving its
user journeys, wording, selected features and repeatable testing. Supporting tools,
tests and related Azure resources were deliberately deleted during the initial
reset. They have since been restored and an isolated release-qualification
environment has been deployed. Old checkpoints and repair targets still do not
describe that installation or authorize recreating the deleted environments.

**[MILESTONES.md](MILESTONES.md) is the sole completion and acceptance record.**
Read [AGENTS.md](AGENTS.md) for project instructions and
[project state](docs/project-state.md) for continuation context.

## Main user journey

1. Deploy through the canonical installer using a separately reviewed current
   plan after the release prerequisites have passed.
2. Sign in to the Admin UI with the appropriate Gateway role and open Getting
   started for readiness and the next permitted action.
3. Review the agent identity, choose a new or existing compatible blueprint, then
   review telemetry and protection choices before submitting registration.
4. Save the API endpoint, external agent ID and one-time Gateway key. Acknowledge
   secure key storage before continuing; any offered HTTPS connection example
   contains no key.
5. Follow the signed-in administrator handoff for Agent 365 Registry creation.
   Eligible automatic completion requires the same circuit's saved-key handoff
   and server-advertised permission. The worker then verifies the connection.
6. Evaluate each prompt before generation, then submit the resulting activity
   and interaction with the evaluation receipt.
7. Inspect processing status, protection evidence and operational history.

Each registration has a distinct child Agent Identity. Multiple registrations may
share a blueprint and its Purview policy. Registration status `Active` does not
by itself prove that a selected protection or telemetry destination is ready.
Deleting a registration removes it from Gateway use; the current worker preserves
Microsoft identities and other external resources.

Requested protection defaults are not silently changed to Off when prerequisites
are unavailable. Resolve those prerequisites or explicitly choose Off before
registration. Creation waits for the browser to acknowledge retention of the
non-secret `pendingExternalId` recovery URL; missing or failed acknowledgement
sends no create. If the create response is lost afterward, reopen that URL and
check the existing registration. Refresh does not repeat creation or recover the
original key.

Optional Purview setup is a separate task. Its Windows companion signs in the
intended administrator and reads classifier definitions; it does not enable DLP
or transfer the sign-in session. Settings explains how to open PowerShell 7 in
the download folder and review/trust that one file without changing execution
policy. Copy the entire `A365GW_CONNECTION_RESULT:` line into **Paste companion
result**; no manually created file is required. An already saved result can be
uploaded optionally with the same checks. Submitting its result continues the original
connection operation while the Gateway checks its own app access. Reopen that
operation after an uncertain response instead of submitting again. See the
[connection and inventory guide](docs/architecture/protection-settings-plan.md#tenant-connection-and-inventory).
**Go to companion result** jumps to the paste field without changing that
operation. If the browser cannot save its recovery link before submission, the
page explicitly says that no confirmation or protection change was sent and
explains how to reload, check status and review again. This is different from an
unknown result after submission, which requires same-operation readback.
The four setup steps are **Connect tenant**, **Set shared policy**, **Test
behavior**, and **Review agent choices**. Their current-step highlight means
location, not completed protection. Connection reports the number of available
SITs; it does not ask for a throwaway selection. Choose the actual types once in
the policy editor, then adjust their explained starting thresholds. Existing
saved values and edited draft values are preserved. The selected blueprint
defines shared scope; a shared policy is not private to one agent.
The automation app also needs its exact
[Security & Compliance reference](operations/README.md#purview-automation-reference-prerequisite);
an Entra identity or successful human catalog read alone does not supply it.

After a protection operation, Settings explains **what happened**, **why it
matters**, **what remains**, and the **next step**. Connection verification leads
to reviewed shared-policy configuration; a saved Enforce policy leads to a
separately approved behavior test, and its result leads to the agent's own
protection choices. Off and simulation have their own valid outcomes. Technical
steps remain available in a collapsed disclosure; Skipped means not run, not
passed. Pending operations receive bounded read-only updates, with explicit
stop/resume and same-operation recovery. Viewing or refreshing these pages never
repeats a mutation, submits samples or enables an agent. Historical completion
does not override expired or unavailable current readiness.

## Installation status

The entry point remains `./gateway setup` on macOS/Linux or `.\gateway.cmd setup`
on Windows. Authored tools and baseline tests are present again. The canonical
terminal lifecycle has been exercised in a separate Azure qualification
environment; its source, platform and verification limits belong to **M5** in the
milestone record. **M6's fresh hosted product journeys remain separate.**
Qualification does not establish production admission, completed registrations,
downstream delivery or effective tenant protection.

| Source | Role in the workflow |
|---|---|
| [Gateway.Setup](tools/Gateway.Setup) | Temporary local setup UI |
| [Gateway.DatabaseMigrator](tools/Gateway.DatabaseMigrator) | Database initialization and reviewed migration tooling |
| [Gateway.LiveVerification](tools/Gateway.LiveVerification) | Separately authorized live verification tooling |
| [Tests](tests) | Deterministic source, behavioral, provider/UI and local SQL fixtures |

Generated `bin/` and `obj/` files do not replace those sources or establish a
clean build. M1 covers the restored tooling and reproducible behavioral baseline;
M5 and M6 cover release and hosted acceptance. See the
[bootstrap guide](bootstrap/README.md) for the retained installer contract.

The retained Registry provisioning path is a Development-only preview; production
admission remains closed. Pinned build inputs include [global.json](global.json),
[Directory.Build.props](Directory.Build.props), [VERSION](VERSION) and
[nuget.config](nuget.config).
Purview executor packaging additionally requires the Windows runtime versions
described in the bootstrap guide.

## Local source and behavioral validation

The design reference for UX flows, wording and screen layouts is the
[UX design package](docs/ux/README.md), including a local interactive prototype
and acceptance scenarios for M3/M4. Current core and protection source behavior
is described in these guides; verification and milestone acceptance remain only
in the milestone checklist. Prototype interactions are separate synthetic design
fixtures, not production or provider acceptance.

The local baseline entry point is:

```powershell
.\tools\Test-LocalBaseline.ps1 -IncludeSql
```

It requires Git, PowerShell 7, the SDK selected by [global.json](global.json),
Pester 5.6.1 and Windows SQL Server LocalDB for the explicit SQL path. Dependency
restore uses the repository's [NuGet feed configuration](nuget.config). The
runner copies tracked and untracked authored files into a new isolated source
directory, excluding generated output and operational state, then builds Release
and runs the allowlisted test projects. Tests are not discovered by executing
arbitrary operator scripts. Empty, skipped or partially passing runs fail.

Without `-IncludeSql`, only non-SQL checks run and the output explicitly says SQL
was not verified. Local SQL uses synthetic data and uniquely owned disposable
databases, never a supplied Azure database connection or administrator credential.
Use `-KeepWorkDirectory` only when retaining the isolated source/results for
diagnosis; otherwise the runner removes only its exact owned run directory.

This command is development validation, not a deployment, signed Windows-package
verification, or proof of Microsoft provider behavior. The milestone checklist
records which acceptance conditions have actually passed.

## External-agent integration

The retained [sample client](src/ExternalAgent.Sample/Program.cs) demonstrates the
flow. After a verified deployment, use the API URL and external ID from the Admin
UI. It reads the Gateway key through a non-echoing prompt.

The sample accepts only HTTPS API URLs. The Admin UI may display a local HTTP
loopback endpoint, but then offers HTTPS guidance rather than an executable sample
command.

```bash
dotnet run --project src/ExternalAgent.Sample -- \
  --api-base-url https://YOUR-GATEWAY-API/ \
  --external-agent-id YOUR-EXTERNAL-AGENT-ID \
  --tenant-user-object-id YOUR-USER-OBJECT-ID \
  --message "Hello through the Gateway"
```

The sample calls `POST /api/v1/prompts:evaluate` before its fixed-response stub.
Generation requires a consistent allowed response with a matching, unexpired
evaluation receipt. The sample checks proof on evaluation and checks its deadline
again after activity ingestion, immediately before the model callback. Replace
the stub callback with the model call while keeping that gate.
The completed interaction carries the same receipt as
`promptEvaluationReceiptId`; the server checks its prompt, identity, expiry,
one-time consumption and protection context again.

A protection change can invalidate a receipt during generation. The sample does
not automatically repeat generation, obtain replacement proof after generation,
or retry uncertain ingestion. It submits the original receipt once after the
model call, even if generation outlasted its validity; server rejection is not a
reason to mint replacement proof for that response.

Runner exit `0` and the final `[ACCEPTED]` summary require valid, matching HTTP 202
receipts with recognized nonfailing processing fields for both submissions.
Per-step `[ACCEPTED]` lines describe only their own request. Neither means
processing completed or any telemetry destination received the data. Evaluation
HTTP 403 returns `3` and `[BLOCKED]`; failed or unconfirmed execution returns `4`.
Malformed 202 receipts are `[UNKNOWN]`, and reported processing failures are
`[FAILED]`. Argument/key-format rejection remains exit `2`. An allowed
`SimulationUnavailable` result still requires valid proof and prints a warning,
not a protection-success claim.

Output contains bounded statuses and identifiers, never raw response bodies,
keys, prompts or generated text. Use synthetic command-line message text and
keep secrets out of command arguments and logs. See the
[API guide](docs/api/api-contract.md) and [OpenAPI](docs/api/openapi.yaml).

## Telemetry and protection

| Capability | Product behavior |
|---|---|
| Agent 365 observability | Registration-scoped sanitized activity export, selected independently from Azure Monitor. |
| Azure Monitor mirror | Sanitized telemetry through the Gateway monitoring pipeline. |
| Prompt Shields | Per-agent prompt attack evaluation through Azure AI Content Safety. |
| Microsoft Purview | Tenant collection settings and shared blueprint DLP configuration, with separate runtime evidence. |

Deployment capability, administrator configuration and effective runtime behavior
are separate facts. Prompt Shields uses a verified Content Safety/managed-identity
binding. Purview distinguishes tenant connection, classifier inventory, policy
readback, propagation, token roles and runtime results. Simulation or accepted
audit submission must not be shown as proven enforcement.

Settings separates the optional tasks into `/settings/connection`,
`/settings/policy`, `/settings/runtime`, `/settings/collection` and
`/settings/defaults`. Both per-agent protections may be intentionally Off without
making core registration incomplete. Shared summaries distinguish installed
capability, saved choice and current protection; unknown is not Off, and a
completed configuration operation is not an enforcing profile.

Purview readiness snapshots include an optional known expiry bound. At expiry,
a cached positive state is no longer current; a policy or identity change can
invalidate it sooner. Approved runtime samples stay in private browser JavaScript until
explicit submission through the administrator-only HTTPS portal. Saved reports
are historical observations, not a replacement for current readiness or proof of
live provider acceptance. See the [protection guide](docs/architecture/protection-settings-plan.md)
for review, recovery and sample-handling boundaries.

Purview Know Your Data uses the fixed tenant-wide enterprise-AI-apps `Group`
location. DLP uses the selected blueprint application ID as an `Individual`
location. Both use the Application enforcement plane. Changes to a shared profile
must make their affected registrations clear.

## Architecture and operation

The Blazor Admin UI calls the Gateway API, which enforces authorization and stores
durable work in SQL. An outbox sends work to Service Bus for the provisioning and
protection workers. Purview administration uses a separate Windows executor;
runtime prompt evaluation uses the configured provider identities. These
boundaries support recovery without assuming exactly-once delivery.

- [Documentation hub](docs/README.md)
- [Product brief](docs/spec/product-brief.md)
- [System architecture](docs/architecture/system-architecture.md)
- [Protection design](docs/architecture/protection-settings-plan.md)
- [Bootstrap and configuration](bootstrap/README.md)
- [Infrastructure assets](infrastructure/README.md)
- [Operator workflows](operations/README.md)

Guides explain behavior. Only the milestone checklist records accepted completion.
