# Design: standing questions / tasking

*Status: proposed (backlog — not started). Companion to the backlog entry in
[`roadmap.md`](roadmap.md).*

## Problem

Between profile refreshes the anchor's priorities are frozen. A real analyst
gets re-briefed on Monday — "this month, weight pricing news higher", "we're
deciding on a vendor; watch for anyone shipping X" — and adjusts without
rewriting their whole brief. The monitor has no equivalent: the rubric only
moves at a re-bootstrap (deliberate, heavyweight, monthly-ish), and the two
calibration channels are *reactive* — thumbs grade what already surfaced,
missed-signal reports name URLs after the fact. There is no way to point the
monitor's attention **forward** at something that hasn't appeared yet.

The obvious hack — editing `relevance.rubric` by hand — is worse than nothing:
it mutates the human-approved ground truth outside the review gate, and nobody
remembers to un-edit it when the decision ships. Whatever carries a tasking
must therefore be (a) separate from the approved profile, (b) visibly
**time-boxed** so a stale tasking can't skew scoring indefinitely, and
(c) injected the way live calibration already is — layered on top of the
rubric, never replacing it.

## What the operator sees

**Portal — Review tab** gains a **"Task the monitor"** box under the
missed-signal box (the two are siblings: one corrects the past, one directs
the near future):

```
Task the monitor
┌──────────────────────────────────────────────────────────────┐
│ Watch for anyone shipping usage-based pricing for agents     │
└──────────────────────────────────────────────────────────────┘
Expires after [30] days        [ Add tasking ]

Active taskings
• Watch for anyone shipping usage-based pricing for agents — expires Jul 11  [retire]
• Weight EU-regulatory items higher this month — expires Jun 28              [retire]
```

**Reports** — the weekly digest footer lists active taskings in one
deterministic line ("Standing taskings: …, expires …"), so the operator is
reminded what is currently skewing scoring and silence stays explainable. The
daily adds nothing; items a tasking pulled in are just items.

## Design

### Architecture (no new claude pass; the live-calibration pattern reused)

```
portal "Task the monitor" box ──POST /focus──> state/focus.jsonl
                                                (append-only, latest-per-id)
  |
  | bin/focus.py active --as-of TODAY     (deterministic: drop expired/retired)
  v
STANDING TASKINGS prompt block (every monitor run, daily + weekly)
  layered on the rubric like RECENT OPERATOR GRADES
  |
  v
weekly footer line (deterministic, post-editor)  +  portal Overview card
```

### The tasking record (`state/focus.jsonl`)

One JSON object per line, append-only, latest-row-per-id (the
`feedback.jsonl` convention; retiring = appending):

```json
{
  "timestamp": "2026-06-11T09:14:00Z",
  "id": "f-9c2d1e0f",                 // "f-" + 8 hex of the lowercased text
                                       // (re-adding the same tasking renews it
                                       //  instead of duplicating)
  "text": "Watch for anyone shipping usage-based pricing for agents",
  "expires": "2026-07-11",             // created + N days; ALWAYS set
  "status": "active"                   // active | retired
}
```

Every tasking expires — there is deliberately **no "forever" option**. A
priority that's still true at expiry gets re-added in five seconds, or has
proven durable enough to belong in the profile at the next refresh. This is
the design's core safety property: the failure mode of a tasking system is
the tasking nobody remembers, and expiry makes that failure self-limiting.

### Recording (portal)

`bin/portal.py` gains a `POST /focus` route beside `/missed`, the same shape:
`record_focus(text, days)` appends the row (id from the hashed text, like
`missed_id()`); a `retire` link appends a `status: "retired"` row under the
same id. The Review tab lists active taskings via the latest-per-id reader.
Input is operator-typed free text rendered through the existing `esc()`
escaping everywhere it's shown. Localhost-only, like grading.

### Injection (`monitor.sh`, every run)

`bin/focus.py active --as-of "$TODAY" state/focus.jsonl` emits the active rows
(latest-per-id, `status: active`, `expires >= as-of`), capped at a constant 5
(more than five simultaneous priorities isn't tasking, it's a new profile).
The block rides next to `$FEEDBACK_NOTE` with rules in the same voice:

- These are the operator's **standing taskings** — time-boxed priorities
  recorded after the rubric was approved. Treat each as scoring guidance
  layered on top of the rubric: give items matching a tasking the benefit of
  the doubt at the margin, and give their likely sources sweep attention this
  run.
- A tasking **adjusts weight, it does not create scope**: it cannot make an
  out-of-scope item in-scope, cannot lower the bar for fabrication or
  citation, and never overrides the honesty constraints. For everything the
  taskings don't touch, the approved rubric governs unchanged.
- When an item surfaces *because* a tasking pulled it over the line, say so in
  its so-what ("matches your standing question on usage-based pricing") — the
  operator should be able to see their own thumb on the scale.

### The weekly footer (deterministic, post-editor)

When the weekly run delivers a report and active taskings exist, append one
line after the Coming up section (same mechanism, same reasons — kb/, email,
webhook, and portal all carry it; the editor can't paraphrase it away):

```
*Standing taskings: "Watch for anyone shipping usage-based pricing for agents" (expires Jul 11).*
```

A silent weekly stays silent — like the radar, this adds to a report, never
causes one.

### Expiry is arithmetic, not bookkeeping

Nothing ever writes an "expired" row: `focus.py active` simply stops emitting
a row past its `expires`, the injection stops, the footer line stops, the
Review list moves it to a dimmed "expired" section for a while (operator
memory: "did that ever fire?"). One code path, no cleanup to forget, no way
for a stale tasking to outlive its box.

### Relationship to the other channels (the full calibration picture)

| Channel | Direction | Clock |
|---|---|---|
| thumbs up/down | reactive, item-level | next run (live) + next refresh (durable) |
| missed-signal report | reactive, URL-level | next run + next refresh |
| **tasking** | **proactive, topic-level** | **next run, until expiry — never durable** |
| profile refresh | durable, everything | monthly-ish, human-gated |

Taskings deliberately do **not** feed the bootstrap: they're ephemeral by
design, and silently folding them into a draft rubric would smuggle un-gated
priorities into the approved profile. (Listing recently-expired taskings in
the refresh email as "consider making these permanent" is a v2 idea.)

### Config knobs (all optional, defaulted, stderr note when defaulted)

| Knob | Default | Meaning |
|---|---|---|
| `tracking.focus_days` | 30 | default expiry the portal box pre-fills |
| `tracking.focus_max_lines` | 500 | prune bound for `state/focus.jsonl` |

The injection cap (5 active taskings) stays a constant. No enable knob: an
empty `focus.jsonl` *is* the off state, and the portal box existing costs
nothing.

### `bin/focus.py` (new, stdlib only)

- `active --as-of YYYY-MM-DD [--max N] state/focus.jsonl` — latest-per-id,
  active, unexpired; JSONL out (for injection) or `--format line` (for the
  weekly footer).
- Malformed lines skipped and counted to stderr; missing file emits nothing;
  a row with no/invalid `expires` is treated as expired (fail-closed — an
  unparseable expiry must not become an immortal tasking).

### Failure modes (warn-only; the run and report are never at risk)

| Failure | Behavior |
|---|---|
| no taskings / file missing | no block, no footer, empty Review list |
| all expired | same as none; Review shows them dimmed |
| corrupt rows | skipped, counted to stderr |
| invalid `expires` | treated as expired (fail-closed), flagged in the Review list |
| `python3` missing | note, skip injection + footer |
| agent over-weights a tasking | visible by construction (the so-what names it); a thumbs-down on the result feeds calibration as usual |
| operator forgets a tasking | impossible to forget *indefinitely* — it expires |

## Tests (`tests/run.sh`; claude is stubbed)

1. **focus.py math** via direct invocation: latest-per-id (a retire row wins
   over an older active row), expiry boundary (`expires == as-of` is active,
   the day after is not), invalid `expires` excluded, the cap, malformed rows
   skipped.
2. **Portal:** POST `/focus` appends a well-formed row (id stable across a
   re-add, renewing expiry); `retire` appends a retired row; the Review tab
   lists active and dims expired; text with `&`/`<`/quotes round-trips
   escaped.
3. **Injection:** seed one active and one expired tasking; run the monitor;
   captured prompt contains a `STANDING TASKINGS` block with exactly the
   active one — on daily *and* weekly.
4. **Footer:** weekly with a report + an active tasking → the delivered
   report (and msmtp capture) ends with the taskings line after Coming up; a
   daily run, and a weekly with no report, append nothing.
5. **Default off:** no `focus.jsonl` → no block, no footer, no note.
6. **Pruning** honored at `focus_max_lines`.
7. `shellcheck` on touched shell; `python3 -m py_compile bin/focus.py`.

## Cost

Zero new claude passes; a few injected lines per run inside the existing
`budgets.monitor_max_turns`. The feature's real cost is the risk of skewed
scoring, and that's bounded by design: capped at 5, visible in every weekly
footer and on the portal, and guaranteed to expire.

## Out of scope / v2 ideas

- **Refresh handoff** — list taskings that expired since the last bootstrap in
  the draft-review email: "these were priorities recently; make any of them
  permanent?" Keeps the human gate while closing the loop.
- **Tasking → expectation** — a tasking with a deadline ("decision by Q3")
  could register a forward-radar expectation, unifying the two (already noted
  in [`design-forward-radar.md`](design-forward-radar.md)).
- **Answered-tasking detection** — let the agent mark a tasking "answered"
  with the item that answered it; v1 keeps the file operator-written only
  (one writer, simpler trust story).
- **`state/focus.md` free-form briefing** — the backlog's alternate shape; a
  structured JSONL with expiry won on safety (free text can't expire a
  sentence at a time).
