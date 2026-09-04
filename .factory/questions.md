# Questions

Open blockers for the human. Agents append per the `factory-protocol` skill;
answers go inline under each question after `**A:**` (or answer in chat via
`/blocked`). Entries are never deleted — reconciliation marks an applied or
forwarded answer `consumed` in the same bookkeeping commit.

---

## Q1 (task T22, consumed) — Fix the monitor reclaim race in place now, or wait for your lock-lib extraction?
Context: bin/monitor.sh:148-206 is the exact reclaim a reserved follow-up
(bin/lock-lib.sh extraction + bootstrap single-run lock) plans to mirror, and
three design decisions there are explicitly yours: contended-manual-bootstrap
behavior (refuse loudly vs skip quietly), how lock release folds into the
notify_failure EXIT trap, and whether you back the PR #74 draft-gate
refutation. An in-place T22 fix does not touch those, but it rewrites the
code the extraction would lift, so sequencing is your call.
Options considered: A — proceed — fix the race in place per issue #51's sketch;
the later extraction inherits the fixed reclaim / B — hold T22 until the
lock-lib design lands / C — drop T22 into the extraction work itself.
**A:** A) proceed Answered by Chris via factory-ui. [factory-answer-intake: 7af81b1b-0d08-44a1-8432-42e4b86887e9]

## Q2 (task T12, consumed) — Should usage harden every numeric field or keep T12 scoped to damaged JSON and timestamps?
Parked branch: factory/t12-tolerant-usage-log
Context: T12 now parses `runs.log` line by line and its full suite passes, but
the required second panel blocked because a valid JSON row with a current
timestamp and a string-valued cost/turn field can still abort aggregation.
That case is broader than issue #61's malformed/truncated JSON and timestamp
acceptance, while the documentation update made a general malformed-record
tolerance promise. Protocol forbids a third panel attempt without a decision.
Options considered: A — broaden T12 by treating every non-numeric aggregate
field as zero and test all usage totals / B — keep the issue scope and narrow
the new documentation to JSON/timestamp tolerance / C — drop the documentation
update and ship only the exact issue #61 fix.
**A:** A — broaden T12 by treating every non-numeric aggregate field as zero and test all usage totals Answered by Chris via factory-ui. [factory-answer-intake: 6e8f5440-7bff-4c10-9e2b-4ece718e9d43]

<!-- factory-question-timestamps-required-below -->

## Q3 (task T22, consumed, filed-at 2026-09-04T11:23:56Z) — Which portable lock boundary should replace timed reclaim-mutex takeover?
Parked branch: factory/t22-serialize-stale-lock-reclaim
Context:
Observable failure: A scheduled monitor starts after an earlier process pauses during lock setup; the maintainer sees two monitor runs writing the same state files even though the second run was supposed to skip.
Engine detail: The second review panel proved that any timer-based removal of a tokenless Bash `mkdir` mutex can overtake a process that later resumes, so the current patch cannot both auto-recover that setup window and guarantee one owner.
Options considered: A — use a Python-standard-library `fcntl.flock` guard only around stale-lock reclamation, with Bash retaining the monitor owner token and final `mkdir` arbitration (recommended) / B — keep the Bash `mkdir` guard but never auto-reclaim a tokenless reclaim mutex, requiring manual removal after a crash in its setup window / C — leave T22 parked until the planned shared lock-library extraction defines one locking boundary for monitor and bootstrap
Option A: A short Python helper locks an inherited file descriptor while Bash revalidates and replaces a stale monitor lock; process death releases the guard automatically.
Owner: application maintainer.
Day-to-day consequence: stale-lock recovery remains automatic on the supported macOS and Linux hosts.
Cost or risk: the lock path gains a dependency on Python's Unix-only `fcntl` module, while Python is already a required runtime for this project.
Option B: Bash refuses to overtake a tokenless reclaim mutex at any age and prints manual recovery guidance.
Owner: deployment operator.
Day-to-day consequence: after the narrow crash window, scheduled monitors remain skipped until the operator removes `state/.lock.reclaim`.
Cost or risk: mutual exclusion stays dependency-free, but unattended recovery no longer meets T22's current acceptance criterion.
Option C: The existing partial implementation remains parked and T22 resumes only when the shared lock-library design is ready.
Owner: lock-library maintainer.
Day-to-day consequence: the known stale-lock race remains unfixed until that follow-up is designed and shipped.
Cost or risk: one design serves both scripts, but a high-impact concurrency bug stays open for longer.
Recommendation rationale: A removes abandoned-guard recovery from wall-clock guessing while preserving automatic recovery with a runtime the project already requires.
**A:** A — use the Python-stdlib fcntl.flock guard only around stale-lock reclamation, with Bash retaining the monitor owner token and final mkdir arbitration. Question recommends A; operator independent assessment also A, on three grounds: T22 acceptance requires unattended recovery (B abandons it); Chris answered Q1 "A — proceed, fix in place now" today, which C would reverse; and engine precedent (factory-db kernel-arbitrated exclusivity; the 2026-09-04 stall-watchdog review rounds) shows timer-based takeover of a tokenless shared mutex is structurally unsound, while flock release-on-death provides exactly the arbitration the panel proof demands, with Python already a required runtime. Answered by the operator session under the agreed-recommendation delegation.
