# Project continuation state

Updated: 2026-09-16.

Read [the milestone checklist](../MILESTONES.md) for completion. This document
records context and the next action, not a second acceptance ledger.

## Current context

The user reset the supporting files and related Azure resources and identified the
retained application as a working baseline. Development is organized around UX,
wording, selected features and repeatable testing. Historical deployment and test
claims have no current acceptance authority.

The preceding review inventoried 698 authored files (excluding bin/obj output),
with complete reads of the Admin UI/contracts/sample/domain and major integration
areas and targeted review of the largest bootstrap/repair modules. Exhaustive
remaining source review is an explicit M1 task.

The retained solution references three absent tools: Gateway.Setup,
Gateway.DatabaseMigrator and Gateway.LiveVerification. The former tests/ directory
is absent. Existing operational test scripts vary between offline, provider-read
and provider-mutating behavior. Re-establish a minimal portable development/test
baseline under M1 before claiming a clean solution build or regression coverage.

## Execution scope

Use the tenant, subscription, browser and credential-handling rules in
[AGENTS.md](../AGENTS.md). The supplied credential must not be requested again or
copied into repository state. Reuse its authorized session where available.

No replacement application environment has been deployed during reorientation.
An existing bootstrap/config.json or historical repair target is not evidence of
a current installation. Future deployment planning pins the named subscription
and verifies the actual target rather than resuming deleted environments.

## Continuation

The next task is M1.1: finish the remaining file-by-file source review, especially
the largest bootstrap and maintenance modules, and reconcile their current
journeys and invariants with the existing guides. Then continue M1 in checklist
order while retaining current application behavior. No application build or
runtime tests ran during the documentation/access milestone. At each closure
update this paragraph to the next unchecked task and reconcile every project
document, directive and memory file with the source.
