# Security policy

## Report a vulnerability

Do not disclose a suspected vulnerability, credential, tenant identifier, or
sensitive diagnostic in a public issue or discussion.

Use the repository's private GitHub vulnerability-reporting or Security Advisory
channel when available. If it is unavailable, contact the repository owner privately
and initially provide only enough information to establish a secure follow-up
channel. Never include credentials, access tokens, Gateway keys, prompts, responses,
customer content, or `.secret`/`.secrets` values.

A useful report identifies the affected version or commit, component, impact,
reproduction conditions, and a safe proof containing no secrets or tenant data.

## Supported code

Security fixes target the current default branch. Archived snapshots and older
workflow formats are compatibility material, not supported deployment releases.

## Security boundaries

- The Gateway API, not the Admin UI, is the authorization boundary.
- Control-plane endpoints require authenticated users and exact Gateway app roles.
  Registry completion additionally requires the reviewed delegated OBO scopes and
  caller identity.
- Workload access uses managed identity and federation. Do not add a client-secret
  fallback.
- Data-plane ingress uses a registration-scoped Gateway key. The API resolves the
  bound registration before cross-checking the body `externalAgentId`.
- A clear Gateway key is returned once. The Gateway stores only a salted verifier
  and lifecycle data; the clear key never belongs in URLs, logs, SQL, queues,
  documentation, or chat.
- Approved interaction content belongs only in the encrypted content store with
  documented retention. It must not appear in logs, diagnostics, the Admin UI, or
  provisioning messages.
- Never read, render, print, log, alter, copy, transmit, or commit `.secret` or
  `.secrets` values. Bootstrap configuration and ignored `.bootstrap/` state are
  non-secret.
- Every external mutation must be discoverable, verifiable, and safe after
  redelivery. SQL locking does not make Service Bus exactly once.
- Unknown, unsupported, unauthorized, or unverifiable provider behavior fails
  closed and must not be reported as `Completed`, `Active`, or synchronized.

Agent 365 Registry and some Agent Identity surfaces are preview dependencies.
Prompt Shields and Purview are optional runtime features. Purview keeps Microsoft's
fixed Know Your Data Group scope separate from blueprint Individual DLP; policy
readback alone is not propagation or runtime-verdict proof.

## Operational response

For an active incident, follow the
[incident response runbook](docs/operations/incident-response.md). Preserve safe
audit, queue, outbox, revision, digest, and correlation evidence without accessing
message bodies or disclosing secrets. Credential and certificate changes must
follow the [rotation runbook](docs/operations/credential-rotation.md).
