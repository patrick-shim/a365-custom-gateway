# Project continuation state

Updated: 2026-09-16.

Read [the milestone checklist](../MILESTONES.md) for completion. This document
records context and the next action, not a second acceptance ledger.

## Current context

The user reset the supporting files and related Azure resources and identified the
retained application as a working baseline. Development is organized around UX,
wording, selected features and repeatable testing. Historical deployment and test
claims have no current acceptance authority.

The baseline audit inventoried 702 tracked authored files, excluding generated
output. The subsequent remaining source-review pass covered the large bootstrap,
maintenance, executor/recovery and operational-wrapper files through EOF. Existing
guides now describe their current journeys and failure/recovery boundaries, and
keep known runtime limitations distinct from accepted baseline behavior.

The solution now includes restored Gateway.Setup, Gateway.DatabaseMigrator and
Gateway.LiveVerification source plus new bounded unit, SQL, provider, UI, setup,
tooling and source-contract fixtures. These are not a wholesale recovery of the
former test tree. Use the [local baseline command](../tools/Test-LocalBaseline.ps1)
for fresh source-bound validation rather than reusing prior test output.
Existing operational scripts vary between portable fixtures, historical-artifact
tests, provider reads and provider mutations; the local runner uses an explicit
allowlist rather than executing the whole directory.

## Execution scope

Use the tenant, subscription, browser and credential-handling rules in
[AGENTS.md](../AGENTS.md). The supplied credential must not be requested again or
copied into repository state. Reuse its authorized session where available.

No replacement application environment has been deployed during reorientation.
An existing bootstrap/config.json or historical repair target is not evidence of
a current installation. Future deployment planning pins the named subscription
and verifies the actual target rather than resuming deleted environments.

## Continuation

Paused at the user's request on 2026-09-16 at 11:57 +08:00 before closing the
laptop. Do not continue implementation, start M2, launch a local server/test run,
or touch Azure until the user explicitly resumes.

Resume from the local Git checkpoint on `main`: read this file, the milestone
checklist, AGENTS.md and MEMORY.md, then inspect `git status` and the latest commit
before editing. All M1 task checks are retained in the milestone checklist; M2
remains unchecked. The validation workspaces were cleaned up, and their generated
binaries are not required to resume.

The next development task is M2.1: define role-specific journeys and acceptance
design without changing the retained identity, confirmation, receipt and recovery
contracts. M2 has not been started.
M1's actual verification is recorded only on its checklist items, not duplicated
here.

The current list/cursor/search limits, telemetry attempt-versus-delivery gap,
fresh Purview provider-reference prerequisite and short-lived readiness are still
described in the guides. Baseline fixture success does not resolve those later
behavioral or hosted acceptance tasks. No replacement Azure environment, live
provider acceptance, signed Windows package or full migration acceptance was
established by the local baseline.

When later validation is needed, use `.\tools\Test-LocalBaseline.ps1 -IncludeSql`;
the final SQL test category is `SqlServer`. Do not reintroduce the superseded
`Sql` selector or rely on an old test result. Browser tabs and cached sign-in
sessions may not survive laptop sleep; re-establish only the context needed for
the resumed task, without resuming deleted deployments or requesting the supplied
password again.
