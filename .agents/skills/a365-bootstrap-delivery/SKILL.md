---
name: a365-bootstrap-delivery
description: Continue or release the A365 Gateway public bootstrap as one evidence-bound, end-to-end delivery from fresh clone through live verification. Use for bootstrap implementation, recovery, deployment, validation, documentation, or agent handoff work; do not use for unrelated Gateway feature development.
---

# A365 bootstrap delivery

Treat bootstrap as one public product journey, not independent scripts.

## Start or resume

Before any task action, read [references/recording-contract.md](references/recording-contract.md). Use `scripts/worklog.ps1` to resume the active delivery session or start one when none exists. Read only `CURRENT.json`, the active manifest, the tail of the active journal shard, and handoffs named by the current checkpoint. Do not reconstruct current state by rereading all historical logs.

On a receiving clone or pull:

1. If `.agent-runtime/bootstrap-delivery/CURRENT.json` exists, validate and resume it.
2. If it is absent, read the tracked `docs/agent-continuation.md` completely. Do not copy a runtime ledger, `.bootstrap/`, `bootstrap/config.json`, `.secret`, or `.secrets` from another computer.
3. From the repository root, start a local source-work session using the checkpoint's current objective, earliest invalidated gate, and exact first unfinished action:

   ```powershell
   pwsh -NoLogo -NoProfile -File .agents/skills/a365-bootstrap-delivery/scripts/worklog.ps1 `
     -Action Start -Actor root -Gate <gate> -WorkItem <bounded-id> `
     -Objective '<current objective>' -Summary '<current safe summary>' `
     -NextAction '<exact first unfinished action>'
   ```

4. Run `pwsh -NoLogo -NoProfile -File .agents/skills/a365-bootstrap-delivery/scripts/validate-worklog.ps1` before recording new work.

The recorder's default runtime root is `.agent-runtime/bootstrap-delivery/` at the
repository root. The older `.agents/runtime/` location remains ignored only for
retained legacy state and is not discovered as the current session. Git transfers
neither runtime location.

Normal validation acquires the writer lock and inspects only the bounded current
snapshot: `CURRENT.json`, the manifest, the current journal shard, and the active
or recent bounded indexes and handoff files. At a release or handoff integrity
gate, or when older-history corruption is suspected, run
`validate-worklog.ps1 -FullAudit`. Full audit scans every historical shard and
handoff under the same writer lock and is not the routine resume path.

A new session refuses to start unless Git can resolve `HEAD` and `docs/agent-continuation.md` is tracked. The manifest and checkpoint record that commit, the continuation path and SHA-256, and only a `Clean` or `Dirty` checkout indicator. They never record dirty filenames or content. A source-only session does not inherit deployment authority or ignored deployment state.

An existing schema-v1 session upgrades lazily on its next valid write. Migration reads only the current shard, preserves the manifest coordinator, and indexes assignments discoverable in that bounded shard. If an older still-active assignment is not indexed, the coordinator records a new assignment; agents never scan historical shards to reconstruct it.

Record an `Intent` before and a `Result` after every material command, tool call, edit, test, decision, delegation, or external action. The journal accepts safe summaries and references only; never record credentials, tokens, Gateway keys, prompts, responses, provider bodies, or authorization headers.

Every delegated work item must have a recipient, owner, exact file or read-only boundary, validation reference, stopping condition, and assignment-start checkpoint. The delegate records a matching structured handoff before reporting completion; the coordinator records receipt and the resulting decision. Delegate events advance journal metadata but cannot replace the coordinator's objective, gate, work item, summary, blockers, or next action.

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
