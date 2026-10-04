# Runtime gateway operations

Operate the current installation with `gateway status`, `gateway verify`,
`gateway doctor`, and `gateway diagnose`. Rebuild/redeploy instructions are in
[the runtime guide](../docs/runtime/README.md).

## Individual-agent DLP verification

Use `tools/scripts/diagnostics/Test-GatewayAgentDlp.ps1` from the repository root with the testing agent's key file, external ID,
tenant user ID, and a new evidence file path. It exercises the public gateway API
with normal and synthetic sensitive input. A readiness/authentication failure is
not a DLP block: require `Purview=Allowed` with a receipt for normal input and
`PROMPT_BLOCKED_BY_DLP` without a receipt for the sensitive sample. Run the C#
`ExternalAgent.Sample` to verify the pre-model gate and normal ingestion, using
stdin for its key. The sample uses a model stub, not a production model.

For scope isolation, use a child under the same blueprint and the same user/input.
A sibling gateway with Purview disabled is only a control; also check its own
Graph protection scope and policy readback. Restore any temporary test access.
See the [policy-consumption guide](../docs/architecture/purview-policy-consumption.md)
for scope checks and enforcement boundaries.

## Runtime queue handling and source checks

RabbitMQ publishers require broker confirmation before outbox completion. Failed
deliveries carry an attempt counter; exhausted workflows are finalized from fresh
durable state. Dead letters are retained in `gateway-provisioning-v3.dead-letter`. The original is acknowledged only
after the retry/dead-letter publication is confirmed. Unknown publish outcomes
can duplicate delivery, so handler idempotency remains required. If durable
finalization is unavailable, the message stays retryable for reconciliation.
Inspect dead letters; do not purge or blindly replay them.

Standalone diagnostics are in [tools/scripts](../tools/scripts/README.md).
Run [source and regression checks](../tests/README.md) before deployment.
