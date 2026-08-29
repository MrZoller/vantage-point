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
Options considered: A) proceed — fix the race in place per issue #51's sketch;
the later extraction inherits the fixed reclaim / B) hold T22 until the
lock-lib design lands / C) drop T22 into the extraction work itself.
**A:**
