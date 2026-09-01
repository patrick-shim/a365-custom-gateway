---
name: a365-bootstrap-delivery
description: Continue or release the A365 Gateway public bootstrap as one evidence-bound, end-to-end delivery from fresh clone through live verification. Use for bootstrap implementation, recovery, deployment, validation, documentation, or agent handoff work; do not use for unrelated Gateway feature development.
---

# A365 bootstrap delivery adapter

Follow the complete Required reading sequence in the binding `AGENTS.md` before
acting. Then read `.agents/skills/a365-bootstrap-delivery/SKILL.md` and every
reference it requires completely, including
`.agents/skills/a365-bootstrap-delivery/references/recording-contract.md`.

The `.agents` skill is the sole canonical bootstrap delivery and ledger contract;
this Claude adapter does not duplicate or override it. When its ignored local
runtime checkpoint is absent after a Git transfer, use
`docs/agent-continuation.md` as the tracked source-continuation fallback and follow
the canonical skill's initialization procedure. Do not infer deployable state or
live authority from source history.
