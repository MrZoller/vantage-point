# Design: forward radar ("Coming up")

*Status: design sketch — not started. Companion to the backlog entry in
[`roadmap.md`](roadmap.md). Same format as
[`design-rubric-backtest.md`](design-rubric-backtest.md).*

## Problem

Everything the monitor produces is retrospective — what happened, what changed.
But the content it sweeps is full of **forward-dated facts**: earnings dates,
"GA in Q3", conference keynotes, regulatory comment deadlines, announced launch
windows. Today those dates are read, maybe mentioned in a so-what, and forgotten.
Three losses follow:

1. **No anticipation.** A human analyst keeps a forward calendar; the monitor
   can't say "Competitor B's earnings are Thursday" on a quiet day.
2. **No accountability for announced dates.** "GA in Q3" passing silently is a
   signal (slipped roadmap, quiet cancellation) that nothing can catch, because
   the expectation was never recorded as a checkable fact.
3. **The dog that didn't bark stays invisible.** The weekly prompt already asks
   for "expected-but-absent" judgment calls, but with no recorded expectations
   it's vibes, not state.

The fix follows the project's own backbone pattern: a small, append-only,
entity-centric state file that the monitor writes as it reads, and that
deterministic code renders and checks.

## What the reader sees

**Weekly digest** — a new deterministic section appended to the report (after
the editor pass, so it can't be paraphrased away):

```
## Coming up

| When        | Entity        | Expected                          | Status |
|-------------|---------------|-----------------------------------|--------|
| Thu Jun 18  | Competitor B  | Q2 earnings call                  | due    |
| by Jun 30   | Competitor A  | usage-based pricing GA ("Q2")     | due    |
| ~Sep (Q3)   | Vendor X      | multi-agent orchestration GA      |        |

Overdue / unconfirmed:
- Competitor C's EU launch was expected "by May" — 3 weeks past, no sign of it.
```

**Daily report** — no standing section (noise discipline); instead, a due
expectation with no evidence past its grace period surfaces as a normal finding:

```
## Shifts
- **Competitor C's announced EU launch is 3 weeks overdue** `[h-9c2d1e0f]` — announced
  "by May" on Mar 4; no launch, no updated date found. Quiet slips often precede
  cancellations or pivots. [original announcement](https://…) _(medium)_
```

**Portal** — a **Coming up** card on the Overview (pending expectations sorted by
due date, overdue ones styled as warnings), and each entity dossier lists its
expectations alongside its event timeline. The static export includes the card.

## Design

### Architecture (no new claude pass)

Recording and checking ride the existing triage run; everything else is
deterministic. This is the cheapest feature in the backlog — its marginal cost
is a few prompt lines and a few injected JSON rows.

```
sweep/score (existing triage pass)
  |  item mentions a forward-dated, time-bounded expectation
  v
state/horizon.jsonl   (append-only; latest row per id wins, like feedback.jsonl)
  |                                  |
  | bin/horizon.py due              | bin/horizon.py upcoming
  |   (deterministic: what's due     |   (deterministic: markdown table)
  |    as of today, grace applied)   |
  v                                  v
DUE EXPECTATIONS prompt block      appended to the weekly report
  (agent finds evidence: met /       (post-editor, pre-promotion, so kb/,
   slipped / overdue -> finding)      email, webhook, portal all carry it)
```

### The expectation record (`state/horizon.jsonl`)

One JSON object per line, append-only, pruned by line count
(`tracking.horizon_max_lines`, default 2000). Latest-row-per-id semantics, same
as `feedback.jsonl` + `dedupe-feedback.py`: an update is a new row with the same
`id`, and readers collapse to the newest.

```json
{
  "timestamp": "2026-06-10T07:00:00Z",
  "id": "h-9c2d1e0f",                 // "h-" + 8 hex of lowercased "entity|event"
                                       // (same convention as item ids; stable, so a
                                       // re-announced date UPDATES instead of duplicating)
  "entity": "Competitor C",            // exact watchlist/profile name (dossier join)
  "event": "EU launch",                // short, stable noun phrase
  "due": "2026-05-31",                 // normalized: the END of the stated period
  "due_precision": "month",            // day | month | quarter | half | year
  "due_text": "by May",                // what the source actually said
  "status": "pending",                 // pending | met | lapsed | withdrawn
  "source": "https://...",             // where the date was announced (REQUIRED)
  "item_id": "a1b2c3d4",               // the surfaced item that carried it, if any
  "note": "announced at partner event"
}
```

Lifecycle, all via appended rows under the same `id`:

- **pending** — recorded, not yet due (a *slip* — "delayed to Q4" — is a new
  pending row with the later `due` and a note; the dossier keeps the history).
- **met** — evidence found that it happened; `source` updates to the evidence URL.
- **lapsed** — overdue past grace, flagged once in a report; appending `lapsed`
  is what stops it re-alarming every subsequent run.
- **withdrawn** — explicitly cancelled by the entity.

No source, no expectation — same rule as observations.

### Fuzzy dates

Normalize every stated window to the **end of its period** plus a precision tag:
"Q3" -> `2026-09-30`/`quarter`, "by May" -> `2026-05-31`/`month`, "June 18" ->
`2026-06-18`/`day`. "Overdue" is `due` + a grace period scaled by precision —
constants, not knobs (nobody should tune these): day +3, month +7, quarter +21,
half/year +30 days. A day-precision keynote missed by a weekend is news; a
quarter-precision GA needs three weeks' slack before crying slip.

### Recording rules (monitor-prompt.md additions, triage step)

Noise discipline is the whole game; the prompt gets hard rules:

- Record an expectation only from an item that **cleared the relevance
  threshold** or concerns a watchlist/profile entity (the observation rule).
- Only **time-bounded** expectations: a stated date, month, quarter, half, or
  year. Never "soon", "eventually", "planned" without a window.
- One expectation per entity+event (the stable id enforces it); an updated date
  is an update, not a new record.
- Record and move on — recording an expectation does not make the item itself
  more surfaceable, and the radar is not a reason to surface marginal items.

### The due check (each run, deterministic prep + agent judgment)

`monitor.sh` runs `python3 bin/horizon.py due --as-of "$TODAY"` and injects the
result (pending rows whose `due` has arrived, with an `overdue_days` field and
`past_grace` flag) as a `DUE EXPECTATIONS` block, alongside the existing
`$CATCHUP_NOTE`/`$CANDIDATES_NOTE`/`$FEEDBACK_NOTE` injections. The agent must,
for each:

- **met** — it happened (often it's in this very sweep): append a `met` row; the
  triggering item flows through scoring as usual.
- **moved** — a new date was announced: append a `pending` row with the new due.
- **due but inside grace, no evidence** — leave it alone; the weekly table shows
  it as "due".
- **past grace, no evidence** — surface a **finding** (the slip is the signal:
  why -> what it suggests -> confidence, citing the original announcement) and
  append a `lapsed` row so it never re-alarms.

This split keeps "what is due" arithmetic in Python and "did it actually
happen" judgment in the agent — the same division as trend detection.

### Rendering (deterministic, weekly)

After the editor pass and before the report is promoted/delivered, when the run
is `weekly` and `horizon.py upcoming --days <horizon_upcoming_days>` emits
anything, append the **Coming up** section to the run report. Appending to the
report file itself (unlike bootstrap's email-only diff fold) means kb/, email,
webhook, and the portal all carry it. Empty-report ethics unchanged: a silent
weekly stays silent — the radar adds to reports, it never causes one.
ASCII-only shell as always; the table content is plain Markdown.

### Portal

- **Overview**: a `coming_up_card()` next to the Feed health card — pending
  expectations collapsed latest-per-id, sorted by due date, overdue-in-grace
  tagged `due`, past-grace styled as warnings. Entity names link to dossiers.
- **Dossiers**: an "Expected" list per entity — pending first, then the
  met/lapsed history (each row's chain shows announced -> slipped -> met).
- Reuses the portal's existing latest-per-id reader pattern; included in the
  static export (server-rendered, no JS).

### Config knobs (all optional, defaulted, stderr note when defaulted)

| Knob | Default | Meaning |
|---|---|---|
| `tracking.horizon` | `true` (when `tracking.enabled`) | record + check expectations; `false` disables everything |
| `tracking.horizon_max_lines` | 2000 | prune bound for `state/horizon.jsonl` |
| `tracking.horizon_upcoming_days` | 14 | window for the weekly Coming up table |

Grace constants and the "time-bounded only" rule stay in the prompt/code — knobs
nobody should turn aren't worth config surface.

### `bin/horizon.py` (new, stdlib only)

Modes, following the `fetch.py`/`dedupe-feedback.py` pattern:

- `due --as-of YYYY-MM-DD` — collapse latest-per-id, keep `status: pending` with
  `due <= as-of`, emit JSONL with computed `overdue_days` + `past_grace`.
- `upcoming --as-of YYYY-MM-DD --days N` — pending rows due inside the window
  plus anything overdue-but-not-lapsed; emit the Markdown table + overdue list.
- Malformed lines skipped; missing file emits nothing; bad dates treated as
  year-precision rather than crashing (fail-safe like everything else).

### monitor.sh sketch

```sh
# after the feedback-injection block:
HORIZON="state/horizon.jsonl"
HORIZON_NOTE=""
if [ "$HORIZON_ENABLED" = 1 ] && [ -s "$HORIZON" ] && command -v python3 >/dev/null 2>&1; then
  DUE="$(python3 bin/horizon.py due --as-of "$TODAY" "$HORIZON" 2>/dev/null || true)"
  [ -n "$DUE" ] && HORIZON_NOTE="

DUE EXPECTATIONS: ... (rules above) ...
\`\`\`jsonl
$DUE
\`\`\`"
fi
# ...injected as $HORIZON_NOTE next to $FEEDBACK_NOTE...

# after the editor pass, before the mv to $REPORT (weekly only):
if [ "$MODE" = weekly ] && [ "$HORIZON_ENABLED" = 1 ] && [ -s "$RUN_REPORT" ]; then
  UPCOMING="$(python3 bin/horizon.py upcoming --as-of "$TODAY" --days "$HORIZON_DAYS" "$HORIZON" 2>/dev/null || true)"
  [ -n "$UPCOMING" ] && printf '\n\n## Coming up\n\n%s\n' "$UPCOMING" >> "$RUN_REPORT"
fi
```

### Failure modes (warn-only; the run and report are never at risk)

| Failure | Behavior |
|---|---|
| `tracking.horizon: false` / `tracking.enabled: false` | no recording, no injection, no section |
| `horizon.jsonl` missing/empty | silently nothing (first runs) |
| corrupt/hand-edited rows | skipped by `horizon.py`, counted to stderr |
| `python3` missing | note, skip injection + section (the prompt's recording rules still apply) |
| agent forgets to record | feature degrades to thinner coverage, never breaks |
| agent forgets to lapse | `due` keeps emitting it; the prompt re-instructs each run — self-healing |
| `upcoming`/append fails | `|| true`, report ships without the section |
| pruning | oldest lines dropped at `horizon_max_lines`, like observations |

## Tests (`tests/run.sh`; claude is stubbed)

1. **Injection:** seed `horizon.jsonl` with one due-past-grace and one
   not-yet-due row; run the monitor; assert the captured prompt contains a `DUE
   EXPECTATIONS` block with exactly the due row (with `past_grace: true`) and
   not the future one.
2. **Weekly section:** stub writes a report; assert the delivered weekly report
   (and the msmtp capture) ends with a `## Coming up` table containing the
   upcoming row; assert a daily run appends nothing.
3. **Silence preserved:** weekly with pending expectations but an empty report
   -> still no report, no section.
4. **Lifecycle math** via direct `horizon.py` invocation: latest-per-id collapse
   (slip updates, met/lapsed rows suppress), grace per precision (month-due +6d
   -> not past grace; +8d -> past), bad dates degrade to year precision.
5. **Disabled:** `tracking.horizon: false` -> no injection, no section, no note.
6. **Corrupt rows** skipped without aborting the run.
7. **Pruning** honored at `horizon_max_lines`.
8. **Portal:** Overview card renders seeded expectations; overdue styled; dossier
   page lists the entity's expectation history; static export includes the card.
9. `shellcheck` on touched shell; `python3 -m py_compile bin/horizon.py`.

## Cost

Zero additional claude passes. Marginal prompt tokens (recording rules + a few
injected rows) inside the existing `budgets.monitor_max_turns`; `horizon.py` is
stdlib arithmetic. The cheapest item on the backlog relative to what it adds.

## Out of scope / v2 ideas

- **`/horizon.ics`** — the portal serving the pending set as an iCalendar feed
  (stdlib-trivial) so expectations land in a real calendar app.
- **Curated calendar feeds** — earnings/conference calendars as bootstrap-derived
  sources feeding the radar directly, rather than only catching dates in prose.
- **Formal dog-that-didn't-bark** — cadence baselines from `observations.jsonl`
  generating *implicit* expectations ("a release every ~3 weeks"); this design
  deliberately covers only *stated* dates, where being wrong is hard.
- **Tasking tie-in** — a standing question ("watching for X") could register an
  expectation with a deadline, unifying two backlog ideas.
