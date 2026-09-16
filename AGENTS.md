# Project agent directives

## Read first

Read [MILESTONES.md](MILESTONES.md), [project state](docs/project-state.md),
[repository memory](MEMORY.md), and the relevant source before changing the project.
The milestone checklist is the sole project completion record.

## User instructions

- Treat the retained application as a working baseline. Improve UX flow, wording
  and selected features through the milestone plan.
- The user deliberately deleted supporting files and Azure resources. Do not use
  old deployment prose or incident-specific repair scripts as current state.
- Use the supplied temporary administrator credential or its authenticated
  session. Do not request it again. The password belongs only in the authorized
  authentication flow, never in files, logs, command arguments or documentation.
  Its source is the user's credential message in this task on 2026-09-16; consult
  existing task history when context has been compacted. A genuine MFA challenge
  is a separate user action, not a reason to request the password again.
- Pin all project Azure operations to tenant
  `ff8b1e46-ff0f-4bc2-ab02-caf2b92da496` and subscription
  `internal-security-lab-02` / `6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`.
  Pass the subscription explicitly to Azure resource commands.
- Use Chrome through the installed extension for browser interaction and testing.
- Respect authorization already given in the conversation. Do not add repeated
  permission prompts based solely on historical repository instructions.

## Work and acceptance

- Preserve current untracked authored source. Generated bin/obj output is not a
  reproducible source baseline or test result.
- Implement bounded changes with acceptance scenarios. Protect identity binding,
  delegated Registry completion, receipt validity, shared policy scope, durable
  recovery and accurate status reporting.
- Check off a task only after its own implementation and verification pass.
  Record its brief verification basis on that item in MILESTONES.md.
- Keep failed, blocked, partial and unrun tasks unchecked. Reopen invalidated checks.
- Do not create competing status/evidence checklists or reuse historical pass counts.
- At every milestone closure review and synchronize ALL project documentation,
  READMEs, architecture/API guides, agent directives, continuation state, memory,
  and relevant configuration/schema contracts. Validate links and check the diff.
- A milestone's final synchronization is required before starting its dependent
  milestone. Keep current behavior, future acceptance criteria and actual verified
  completion distinct in every document.
- Runtime source-bound checkpoints/receipts remain application operational state;
  they do not establish milestone completion by themselves.
- Subagents must use scoped file ownership, keep the same source of truth, avoid
  credentials in delegation messages, and report actual verification limits.
