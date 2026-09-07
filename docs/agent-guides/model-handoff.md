# Model handoff protocol

This protocol applies to Codex, GitHub Copilot, Claude, delegated agents, and human
contributors. Follow `AGENTS.md` and its required reading order first.

Every role and skill must also read and follow
[the end-to-end execution contract](end-to-end-execution.md).
Handoffs preserve the full product objective, acceptance matrix, authorization and
hold references, secure credential-input reference and availability facts, current
phase/gate, evidence and exact next action. Do not turn a completed subtask into a
completed product, a failed prompt into revoked access, or a model switch into a
new approval cycle. Explicit stops remain effective until the affected scope resumes.

Continue the current objective when the model changes. A question, progress
request, or handoff request does not cancel the unfinished delivery. Read
[agent continuation](../agent-continuation.md) for the first unfinished action,
then resume the existing local ledger when available. Do not rebuild current state
from chat, old journal shards, or historical notes.

Use the canonical repository checkout and `main`. The operator requested a single
main checkout, with reviewed work committed and pushed; do not create a branch or
Git worktree unless the operator changes that instruction. Before retiring an old
linked worktree, prove that its commits are merged, preserve uncommitted work and
local-only deployment evidence, and verify the exact removal boundary.

## Before reporting a handoff

1. Reconcile source changes, tests, review findings, and live readback. Distinguish
   implemented, offline-validated, deployed, and independently live-verified work.
2. Update the bounded continuation checkpoint with the objective, exact first
   unfinished action, completed evidence, failed or invalidated gates, active
   reviews, and live-action boundary. An ignored draft is not transferable source.
3. Update implementation and deployment status, relevant runbooks and READMEs,
   Microsoft capability references, comments, and history pointers. Historical
   results belong in Git; they must not contradict the current checkpoint.
4. Audit `AGENTS.md`, `CLAUDE.md`, `.github/copilot-instructions.md`, both sets of
   role specifications, canonical skills, and Claude skill adapters. Keep current
   operational facts in the checkpoints instead of duplicating them in every role.
5. Require a structured delegate handoff and coordinator receipt before adopting
   a delegate's result. Record owner, file boundary, starting fingerprint,
   validation, remaining risk, and next action. No overlapping writers.
6. Run the affected checks and required clean-export gates. Record an unavailable
   or policy-blocked check as unverified; a different passing test does not silently
   close it. Honor an operator's explicit acceptance of an alternate gate.
7. Keep credentials, tokens, Gateway keys, provider bodies, prompts, responses,
   deployment configuration, and operator evidence out of Git. Preserve local
   recovery state separately; never modify an accepted snapshot to fit new source.
8. Under current repository-write authority, commit the reviewed changes on canonical `main`, push, and check the remote
   commit and hosted CI. State any unfinished gate plainly. Verify that no required
   implementation remains only in a worktree or ignored draft.

For ledgered bootstrap reviews, use the `bootstrap-delivery-reviewer` role with
the assignment naming the security, UI, documentation or deployment review scope.
That role permits only the necessary ledger writes alongside source review.
Generic Codex reviewer roles retain their read-only sandbox and cannot create the
mandatory Intent, Result and Handoff records. Do not widen those generic roles or
accept an unrecorded review as a completed bootstrap handoff.

Existing user authorization persists within the active session. Do not ask again
for an action already authorized for the same target and scope. A fresh clone or
another operator session does not obtain deployment authority from Git; original
matching deployment state and current operator authority are still required.

For a stopped Purview prerequisite stage, use the
[dedicated recovery runbook](../operations/purview-prerequisite-recovery.md).
Its completed receipt authorizes only its exact corrected tooling source. It does
not authorize a Windows executor upgrade, certificate rotation, policy replacement,
Registry replay, SQL initialization, or cleanup of another environment.
