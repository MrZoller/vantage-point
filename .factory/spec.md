# Spec: GitHub issue backlog

Spec = the issue tracker for MrZoller/vantage-point; imported 2026-08-29; filter: none.

## Problem

Open repository issues describe defects and maintenance work that need a durable, reviewable path through the factory.

## Outcome

Every open issue is represented by a linked plan task whose acceptance criteria preserve the issue's current requirements, and later backlog syncs append newly opened work without rewriting the imported record.

## Scope

### In

- All open issues in `MrZoller/vantage-point`, with no label filter.
- Issue closure and reopen transitions handled by backlog sync.
- Human approval of each imported or materially changed plan before execution.

### Out

- Closed issues, unless a previously imported issue is reopened.
- Work not represented by an issue, except the factory's rolling parked-review-minors batch.
- Reinterpreting existing imported tasks from later tracker edits; the plan remains the execution record.

## Acceptance criteria

1. Each in-scope open issue has exactly one non-terminal plan task carrying `(Fixes #N)`, except when an issue's previously completed factory task requires a distinct reopen task.
2. Each imported task uses the issue body for testable acceptance and the `major`/`trivial` labels for size, defaulting to standard.
3. A changed import requires `/approve plan` before factory execution resumes.

## Risks & constraints

- GitHub is the external source of scope; issue availability and state must be queried directly during sync.
- Existing task wording, sizing, and numbering are immutable after import.
- The repository's Bash 3.2, Python-standard-library-only, and fail-safe behavior constraints remain in force.

## Open questions

None.
