---
name: a365-bootstrap-delivery
description: Continue or release the A365 Gateway public bootstrap as one evidence-bound, end-to-end delivery from fresh clone through live verification. Use for bootstrap implementation, recovery, deployment, validation, documentation, or agent handoff work; do not use for unrelated Gateway feature development.
---

# A365 bootstrap delivery

Treat bootstrap as one public product journey, not independent scripts.

## Start or resume

Before any task action, read [references/recording-contract.md](references/recording-contract.md). Use `scripts/worklog.ps1` to resume the active delivery session or start one when none exists. Read only `CURRENT.json`, the active manifest, the tail of the active journal shard, and handoffs named by the current checkpoint. Do not reconstruct current state by rereading all historical logs.

Record an `Intent` before and a `Result` after every material command, tool call, edit, test, decision, delegation, or external action. The journal accepts safe summaries and references only; never record credentials, tokens, Gateway keys, prompts, responses, provider bodies, or authorization headers.

Every delegated work item must have a recorded owner and file boundary. The delegate records a structured handoff before reporting completion; the coordinator records receipt and the resulting decision.

## Delivery gate

Read [references/release-gate.md](references/release-gate.md) when changing or releasing bootstrap. Advance the recorded gate only with the required evidence:

1. Plan
2. Build
3. OfflineValidate
4. Deploy
5. LiveValidate
6. UpdateCheckpoint
7. Complete

Do not call a bootstrap change complete from unit tests alone. The release candidate must prove the supported public commands from a clean checkout on Windows, then prove the authorized Azure deployment and live Admin UI/functionality. If a live mutation is not authorized, stop at the gate that requires it and record the exact unmet authority; never imply later gates passed.

## Failure handling

Preserve the current resource group and `.bootstrap` state unless deletion was explicitly requested. Diagnose from the active checkpoint, add a failing regression test, implement the smallest correction, and rerun the gate from the earliest invalidated stage. Record why each later stage was retained or invalidated.

Keep generated journals small: the recorder rotates at 100 events, 128 KiB, or four hours. Put durable product truth in the normal status documents only after it is verified; journals are coordination evidence, not public product documentation.
