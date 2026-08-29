# Plan: GitHub issue backlog

## Approach

Treat the open GitHub issue tracker as the external specification and keep this plan as the immutable execution record. Each issue becomes one independently shippable task linked with `(Fixes #N)`, with acceptance distilled from the issue's named scripts, modules, and observed failure. Issue order follows the first-import collection; later syncs only append or apply explicit closure/reopen transitions. No issue body establishes a semantic prerequisite, so the imported tasks remain independently selectable. Existing Bash 3.2, Python standard-library-only, fail-safe, and end-to-end test conventions govern every change.

## Tasks

- [x] T1 (standard) — tests: fixed server ports + identity-blind wait_port make server tests flaky under contention (Fixes #78)
  - acceptance: server-backed cases in `tests/run.sh` use OS-assigned ports (including portal and capture/static servers), wait for the server they started rather than any listener, and terminate then `wait` for each server; repeated or concurrent suite runs do not fail `test_fetch_verify` through a port collision
  - pr: 80
- [x] T2 (standard) — Minor findings grab-bag: init.err litter, dead nav links in static export, vacuous test assertion, cosmetic nits (Fixes #71)
  - acceptance: successful `bin/init.sh` review removes `init.err`; `bin/portal.py` static exports contain usable static navigation; `tests/run.sh` replaces the non-validating HTMLParser assertion with a check that can detect the targeted malformed output; `bin/bootstrap.sh` renders recipient lists with comma-space separators; and `bin/email-lib.sh` documents the msmtp status behavior it actually provides
  - pr: 81
- [x] T3 (standard) — portal.py: calibration coverage counts first-record-per-id while Review/dossiers use newest — dropped items inflate the denominator (Fixes #70)
  - acceptance: `bin/portal.py` builds calibration and source surfaced counts from the newest record per id and excludes ids whose newest record is `signal: "dropped"`, matching Review and dossier visibility; portal tests cover a surfaced-then-dropped id
  - pr: 82
- [x] T4 (standard) — portal.py: Coming-up card uses local date.today() while every other portal date is UTC (Fixes #69)
  - acceptance: `bin/portal.py` computes the Coming-up card date in UTC so expectation timing and cadence/quiet displays use the same day boundary; tests cover a local-date/UTC-date boundary
  - pr: 83
- [x] T5 (standard) — portal.py vs monitor.sh: tracking.quiet_min_events: 0 normalized differently — portal shows quiet flags the monitor never raises (Fixes #68)
  - acceptance: `bin/portal.py` normalizes zero or invalid `tracking.quiet_min_events` to 4, matching `bin/monitor.sh`, and tests show the portal and monitor apply the same threshold
  - pr: 84
- [x] T6 (standard) — portal.py: grade links never URL-encode the item id, so ids with URL metacharacters break or mis-route grading (Fixes #67)
  - acceptance: `bin/portal.py` percent-encodes review grade and missed-link item ids with no safe metacharacters; tests verify ids containing `&`, `=`, `%`, `#`, `+`, and spaces reach the intended record without query splitting
  - pr: 85
- [x] T7 (standard) — fetch.py: relative entry links resolved against the pre-redirect feed URL (Fixes #66)
  - acceptance: `bin/fetch.py` retains the final URL returned after redirects and resolves relative entry links against it; tests cover a configured feed redirecting to another origin before returning a relative entry URL
  - pr: 86
- [R] T8 (standard) — fetch.py: config parsing loses feeds — '#' truncation without whitespace, and multi-line flow lists yield zero feeds (Fixes #65)
  - acceptance: `bin/fetch.py` preserves `#` fragments in unquoted feed scalars unless whitespace starts a YAML comment, and either parses multi-line flow-list feeds or emits an explicit warning instead of silently yielding no feeds; tests cover both forms
  - pr: 87
- [ ] T9 (standard) — research.py/bootstrap.sh: unbounded facet slug length breaks the stub-note degradation contract (Fixes #64)
  - acceptance: `bin/research.py` bounds filesystem-safe facet slugs before de-duplication so long ids/titles cannot exceed filename limits; `bin/bootstrap.sh` still writes a note or failure stub, JSON stash, and `.failed` marker and reports provenance accurately for a long facet
- [ ] T10 (standard) — email-lib.sh: CID logo emits one giant base64 line on macOS, violating the SMTP 998-octet limit (Fixes #63)
  - acceptance: `bin/email-lib.sh` emits CID image base64 in explicitly normalized 76-character lines on both macOS and GNU tooling; tests exercise a logo large enough to exceed the SMTP line limit
- [ ] T11 (standard) — monitor.sh: deepdive_max_items: 0 empties the queue after the non-empty check, launching a pointless deep-dive pass (Fixes #62)
  - acceptance: `bin/monitor.sh` treats `deepdive_max_items: 0` as disabling/skipping deep-dive work or rechecks the truncated queue, and tests verify no `claude` deep-dive invocation occurs for an empty post-cap queue
- [ ] T12 (standard) — usage.sh: one runs.log row without a valid timestamp aborts the whole rollup (Fixes #61)
  - acceptance: `bin/usage.sh` skips JSONL rows with missing/invalid timestamps and malformed or truncated lines while retaining valid rows in the rollup; tests verify the command remains successful and reports valid usage
- [ ] T13 (standard) — monitor.sh: triage prompt renders "DEEP-DIVE QUEUE: enabledopus." when deep-dive is on (Fixes #60)
  - acceptance: `bin/monitor.sh` renders the triage prompt's deep-dive state as exactly `enabled` or `disabled`; tests cover a configured model without concatenating its name into the state
- [ ] T14 (standard) — fetch.py: no total deadline or size cap on feed fetches — a slow-drip feed stalls the whole run (Fixes #59)
  - acceptance: `bin/fetch.py` reads feeds with a total wall-clock deadline and finite byte cap, treating either breach as a per-feed warning/failure while continuing subsequent feeds; tests cover slow-drip and oversized responses
- [ ] T15 (standard) — demo-bundle.sh: a broken symlink in state/ or kb/ aborts the build, leaving a partial bundle (Fixes #58)
  - acceptance: `bin/demo-bundle.sh` handles dangling symlinks in `state/` or `kb/` with a warning/skip rather than aborting, and still produces the launcher, `START-HERE.md`, copied content, relocation, smoke-test result, and tarball expected of a completed bundle
- [ ] T16 (standard) — monitor.sh: missing last_bootstrapped silently disables the profile-staleness check on Linux (Fixes #57)
  - acceptance: `bin/monitor.sh` checks that `last_bootstrapped` is non-empty before platform date parsing and emits a distinct note when it is absent; tests show consistent Linux/macOS behavior
- [ ] T17 (standard) — backtest.py: baseline agreement deflated when a feedback row lacks a numeric score, flattering the draft (Fixes #56)
  - acceptance: `bin/backtest.py` calculates approved-profile baseline agreement with a denominator containing only rows that have a numeric baseline score, while draft agreement retains its own denominator; rendered output/tests distinguish unscored baseline rows
- [ ] T18 (standard) — monitor.sh: triage claude's 2> truncates the feed-sweep diagnostics written moments earlier (Fixes #55)
  - acceptance: `bin/monitor.sh` preserves feed-sweep statistics and failure diagnostics in the run `.err` file when triage starts, and tests verify later stage stderr appends rather than erases earlier diagnostics
- [ ] T19 (standard) — dedupe-feedback.py: non-string id raises TypeError and aborts the whole bootstrap (Fixes #54)
  - acceptance: `bin/dedupe-feedback.py` skips records whose id is not a string without traceback, preserves valid output, and does not abort `bin/bootstrap.sh`; tests cover an unhashable array/object id alongside valid feedback
- [ ] T20 (standard) — portal.py: one invalid UTF-8 byte in any state file breaks every portal page (Fixes #53)
  - acceptance: `bin/portal.py` tolerates invalid UTF-8 in JSONL state and kb reports without dropping the entire page, and `bin/cadence.py` applies equivalent tolerant reading; tests cover malformed bytes in each reader surface
- [ ] T21 (standard) — portal.py: state-changing GET endpoints (/grade, /missed) have no CSRF/origin protection (Fixes #52)
  - acceptance: `bin/portal.py` rejects cross-origin state changes to `/grade` and `/missed` and prevents DNS-rebinding access through untrusted Host values, using POST plus a per-session token or equivalent origin/host protection; tests verify legitimate localhost actions still append feedback while forged cross-origin requests do not
- [!] T22 (standard) — monitor.sh: stale-lock reclaim race can leave two monitors running concurrently (Fixes #51)
  - acceptance: `bin/monitor.sh` serializes stale-lock reclamation, re-verifies the inspected owner/token before removing a lock, preserves final `mkdir` ownership arbitration, and reclaims an abandoned reclaim mutex after the setup grace; a contention test proves two reclaimers cannot both own the monitor lock
- [ ] T23 (standard) — bootstrap.sh: a successful run exits 1 whenever no draft summary was written (Fixes #50)
  - acceptance: `bin/bootstrap.sh` exits successfully when synthesis writes `profile.draft.yaml` without the optional summary, still prints the appropriate completion guidance, and has an end-to-end test for a draft-without-summary stub
- [ ] T24 (standard) — webhook.py: a redirect silently drops the report payload, then reports success (Fixes #49)
  - acceptance: `bin/webhook.py` refuses HTTP redirects instead of following them as a bodyless GET, exits nonzero with guidance to use the final webhook URL, and tests verify redirected payloads are never reported as delivered
- [ ] T25 (standard) — fetch.py: uncaught http.client exceptions from one feed kill the entire sweep (Fixes #48)
  - acceptance: `bin/fetch.py` catches `http.client.HTTPException` failures such as `IncompleteRead`, `BadStatusLine`, and `LineTooLong` per feed, continues processing other feeds, and updates feed-health output; tests cover malformed/incomplete server responses
- [!] T26 (trivial) — parked review minors (batch)
  - acceptance: confirmed non-blocking review findings parked during backlog delivery are collected here and shipped together when the batch is made runnable
  - PR #82: make Review and dossier latest-row readers reserve IDs whose newest seen row is `dropped`, so older surfaced rows cannot reappear for grading.
  - PR #82: retain dropped tombstone state (or distinguish it from an ordinary pruned surfaced record) for the calibration fallback after `seen.jsonl` pruning.

## Risks

- Several tasks touch the shared `tests/run.sh` harness; keep each issue's tests scoped to its behavior to minimize merge collisions.
- Network and concurrency fixes need deterministic local fixtures; if a criterion cannot be reproduced without public network timing, stop and design a local server fixture rather than weakening the assertion.
- T21 changes a state-changing portal interface; if POST/token protection cannot preserve the dependency-light localhost workflow, stop for a human design decision.
- T22 changes the monitor's concurrency boundary; if portable Bash 3.2 cannot provide the required ownership invariant, stop before substituting a platform-specific lock primitive.

## Ad-hoc

<!-- user-requested tasks get appended here by the driver -->
