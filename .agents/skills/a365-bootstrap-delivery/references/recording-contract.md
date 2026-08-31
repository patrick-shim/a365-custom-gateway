# Recording and handoff contract

## Purpose

The active delivery state must survive task compaction, app restart, and agent handoff without rereading an unbounded history. The runtime ledger is local-only under `.agents/runtime/bootstrap-delivery/`.

## Bounded layout

```text
.agents/runtime/bootstrap-delivery/
|-- CURRENT.json
`-- sessions/<session-id>/
    |-- manifest.json
    |-- journal/0001.jsonl
    `-- handoffs/<sequence>-<work-item>.json
```

`CURRENT.json` is the only discovery entry point. It stays below 16 KiB and contains the active session, delivery gate, last sequence, current objective, current work item, blockers, next action, and the current journal shard.

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

An assignment records:

- work-item ID and objective
- owner and intended recipient
- exact file ownership or read-only boundary
- starting checkpoint hash
- expected validation and stopping condition

A handoff records:

- observations and changes
- files touched
- validation executed and result
- blockers or residual risk
- exact next action
- ending checkpoint hash

The coordinator does not act on an unrecorded handoff. If parallel agents overlap files, stop one owner and record the ownership change before edits continue.

## Read strategy

On resume:

1. Read `CURRENT.json`.
2. Read its session `manifest.json`.
3. Read only the last 30 events of the named journal shard.
4. Read only handoffs referenced by those events or `CURRENT.json`.
5. Open older shards only when an explicit evidence reference requires them.

This ledger supplements, but does not replace, required repository architecture and safety guidance.
