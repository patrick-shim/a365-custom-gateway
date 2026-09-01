# Recording and handoff contract

## Purpose

The active delivery state must survive task compaction, app restart, and agent handoff without rereading an unbounded history. The runtime ledger is local-only under the repository-root `.agent-runtime/bootstrap-delivery/`.

## Bounded layout

```text
.agent-runtime/bootstrap-delivery/
|-- CURRENT.json
`-- sessions/<session-id>/
    |-- manifest.json
    |-- journal/0001.jsonl
    `-- handoffs/<sequence>-<work-item>.json
```

The older `.agents/runtime/` location remains ignored for retained legacy state.
It is not an active discovery path, and Git transfers neither runtime location.

`CURRENT.json` is the only discovery entry point. It stays below 16 KiB and contains the active session, delivery gate, last sequence, current objective, current work item, blockers, next action, and the current journal shard.

Schema v2 also binds `CURRENT.json` to the active manifest and source checkpoint. Both contain the checked-out Git `HEAD`, `docs/agent-continuation.md` path and SHA-256 fingerprint, whether that file was Git-tracked, and only a `Clean` or `Dirty` checkout state. No dirty filename or content is recorded. `CURRENT.json` keeps at most eight active assignments and twelve recent handoff indexes.

Each journal shard is append-only and rotates before it exceeds any boundary:

- 100 events
- 128 KiB
- four hours from the shard's first event

A completed session is immutable. Start a new session for a new delivery objective; do not append to historical sessions.

## Event protocol

Record two events around every material action:

- `Intent`: what will be done, why, the work item, and owned files or external boundary.
- `Result`: observable outcome, evidence reference, and next action.

Use `Decision` for a choice that changes implementation or recovery direction, `Checkpoint` when the current summary/gate changes, `Assignment` before delegation, `Handoff` before a delegate reports completion, and `Receipt` when the coordinator accepts or rejects a handoff.

Summaries must be factual and short. Reference a file, test name, commit, deployment ID, or sanitized diagnostic path instead of copying long output. Never store secret or content-bearing values.

## Agent communication

An assignment is validated before journal append and records:

- work-item ID and objective
- assigning agent, recipient, and resulting owner
- exact file ownership or read-only boundary
- assigned sequence and the assignment's prior checkpoint hash
- expected validation and stopping condition

A handoff requires a recipient and exactly one matching active assignment before journal append. It records:

- observations and changes
- files touched
- validation executed and result
- blockers or residual risk
- exact next action
- the assignment-start checkpoint hash, assignment sequence, and ending checkpoint hash

The handoff removes that assignment from the active index and appends a bounded recent index containing its path, sequence, work item, participants, and status. The handoff file keeps its own fingerprint. Before journal append, the recorder derives the candidate `CURRENT.json` and optional handoff, fingerprints those exact payloads, and enforces the 16 KiB `CURRENT.json` and 32 KiB handoff limits. Invalid semantics or oversized derived files are rejected without changing the journal, checkpoint, manifest, or handoff indexes.

The manifest is the sole coordinator authority. Delegate events may advance sequence, shard, fingerprint, and index metadata, but only coordinator `Record`, `Checkpoint`, and `Complete` actions may change the global objective, gate, work item, summary, blockers, or next action.

The coordinator does not act on an unrecorded handoff. If parallel agents overlap files, stop one owner and record the ownership change before edits continue.

## Read strategy

On resume:

1. Read `CURRENT.json`.
2. Read its session `manifest.json`.
3. Read only the last 30 events of the named journal shard.
4. Read only handoffs referenced by those events or `CURRENT.json`.
5. Open older shards only when an explicit evidence reference requires them.

If `.agent-runtime/bootstrap-delivery/CURRENT.json` is absent after a fresh clone or pull, read tracked `docs/agent-continuation.md` and use the exact `Start` command in the skill. A new start binds the local source automatically and requires the continuation file to be tracked. Never synthesize current state from chat transcripts or copy another computer's ignored runtime state.

An existing schema-v1 session is upgraded only on a valid write. The bounded migration reads the current shard, not all history, restores coordinator fields from that shard when available, and preserves the legacy event chain. Assignments older than the current shard must be explicitly reassigned rather than reconstructed.

Journal append, handoff-file replacement, manifest replacement, and `CURRENT.json` replacement are separate filesystem operations; a cross-file crash-atomic transaction is not claimed. Input, semantic, and derived-size validation occurs before append. Normal validation acquires the writer lock and checks the bounded current snapshot: the current schema and checkpoint, manifest, current shard, active assignments, and bounded recent handoff indexes and files. It detects a mismatch in that snapshot, an incomplete migration, or indexed-handoff divergence before work continues. `-FullAudit` explicitly scans every historical journal shard and handoff under the same writer lock; use it for a release or handoff integrity gate or when historical corruption is suspected, not for routine resume.

This ledger supplements, but does not replace, required repository architecture and safety guidance.
