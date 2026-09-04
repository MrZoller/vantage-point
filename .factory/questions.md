# Questions

Open blockers for the human. Agents append per the `factory-protocol` skill;
answers go inline under each question after `**A:**` (or answer in chat via
`/blocked`). Entries are never deleted — reconciliation marks an applied or
forwarded answer `consumed` in the same bookkeeping commit.

---

## Q1 (task T22, open) — Fix the monitor reclaim race in place now, or wait for your lock-lib extraction?
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
**A:**

## Q2 (task T12, open; parked branch: factory/t12-tolerant-usage-log) — Should usage harden every numeric field or keep T12 scoped to damaged JSON and timestamps?
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
**A:**
