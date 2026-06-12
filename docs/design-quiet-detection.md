# Design: dog-that-didn't-bark detection (cadence baselines)

*Status: ✅ shipped (Phase 21) — `bin/cadence.py` plus the injection/marking wired
through `bin/monitor.sh`, `monitor-prompt.md`, and the dossier Cadence line in
`bin/portal.py`. This document is the design of record; it matched the
implementation closely (one deviation: the portal loads `cadence.py` by file path
with a no-line fallback, rather than a plain import, so a standalone `portal.py`
copy can't crash). Companion to the Phase 21 entry in [`roadmap.md`](roadmap.md).
The forward radar ([`design-forward-radar.md`](design-forward-radar.md)) shipped
the *stated*-date half of this idea; this design covers the implicit,
cadence-derived half its v2 notes deferred.*

## Problem

An entity going quiet is a finding. A competitor that ships every ~3 weeks and
then says nothing for 8 is telling you something — a pivot, a layoff, a stealth
rework — and a human analyst notices because they carry a feel for each entity's
normal rhythm. The monitor has the data for that feel sitting unused:
`state/observations.jsonl` records sourced events per entity run after run, so
each entity's **normal cadence is computable**.

Today the gap is papered over twice, both badly:

1. The weekly prompt's optional **Quiet on** section asks the agent for
   "notable absence of movement where you'd expect it" — but with no computed
   baseline that's vibes, exactly what the forward radar's design called out
   for stated dates.
2. The forward radar itself only catches a date someone *announced*. Most
   silences were never announced; they're visible only against the entity's own
   history.

The fix is the project's standard division of labor: **deterministic
arithmetic in Python** (what is each entity's baseline, who is past it),
**judgment in the agent** (is it genuinely quiet, or did this very sweep just
show otherwise?), riding the existing runs with no new claude pass.

## What the reader sees

**Weekly digest** — computed numbers behind the existing **Quiet on** section,
instead of (or alongside) the agent's impressions:

```
## Quiet on
- **Competitor A** — no release-type event in 8 weeks vs a ~3-week norm
  (9 events on record since Feb). Last: [v2.4 launch](https://…) Apr 12.
  Their longest gap coincided with the v2 rework; worth a look. _(medium)_
```

**Daily report** — nothing. A silence builds over weeks; flagging it daily is
noise. (If a quiet entity *resumes*, that's a normal item/observation and the
daily covers it already.)

**Portal** — each entity dossier gains one **Cadence** line above its event
timeline ("~3-week event cadence · last event Apr 12 · 56 days quiet ⚠")
rendered from the same arithmetic, so the baseline is inspectable when the
weekly flags it.

## Design

### Architecture (no new claude pass)

```
state/observations.jsonl  (event-type rows, per entity — existing)
  |
  | bin/cadence.py quiet --as-of TODAY        (deterministic: baselines + who
  |                                            is past factor x baseline)
  v
QUIET ENTITIES prompt block (weekly run only)
  |   agent verifies against THIS sweep:
  |   - activity found  -> records the observation as usual (self-healing:
  |                        last_seen advances, the flag clears next time)
  |   - genuinely quiet -> a "Quiet on" finding, citing the last event
  v
state/quiet.jsonl   (flag memory: suppress re-alarms for the same silence)
```

### The baseline (deterministic, `bin/cadence.py`, stdlib only)

Per **entity + event_type** (a release rhythm and a hiring rhythm are different
clocks), over `metric == "event"` rows in `observations.jsonl`:

- Collect the observation timestamps, oldest first; require at least
  `tracking.quiet_min_events` (default 4) — below that "normal cadence" is a
  guess, and guessing is the failure mode this replaces.
- Baseline = the **median** inter-event gap in days (median, not mean: one long
  holiday gap shouldn't poison the rhythm).
- Quiet when `as_of - last_seen >= max(quiet_factor x median, 14 days)`. The
  factor (default 3) is the sensitivity knob; the 14-day floor is a constant
  (like the radar's grace constants — a knob nobody should turn): an entity
  with a 2-day cadence going silent over a long weekend is not a story.

Mention-count metrics are deliberately **excluded** from v1: mention volume
depends on how thoroughly each run swept, so a "mentions went quiet" baseline
measures our own coverage as much as the entity. Event observations are
sourced facts ("no source, no observation"), which makes their absence
meaningful.

Output of `quiet` — one JSON row per quiet entity, for injection:

```json
{
  "entity": "Competitor A",
  "event_type": "release",
  "n_events": 9,
  "median_gap_days": 21,
  "last_seen": "2026-04-12",
  "last_source": "https://...",
  "silence_days": 56,
  "factor": 2.7
}
```

### Re-alarm suppression (`state/quiet.jsonl`)

Without memory, a quiet entity re-flags every weekly until it resumes — the
radar solved the same problem with `lapsed` rows. Here the memory is a small
append-only file, latest-row-per-key (`entity|event_type`), written
**deterministically by the script** (not the agent — unlike horizon updates
there is no judgment in "this was flagged"):

```json
{ "timestamp": "...", "entity": "Competitor A", "event_type": "release",
  "last_seen": "2026-04-12", "flagged": "2026-06-08" }
```

- `cadence.py quiet` drops any quiet row whose `(entity, event_type,
  last_seen)` matches a flag row — same silence, already reported.
- `monitor.sh` runs `cadence.py mark` with the injected rows after the weekly
  report is promoted, recording the flags. If the agent found activity instead,
  it recorded an observation, `last_seen` advanced, and the stale flag simply
  never matches again — the episode resets on resumption with no cleanup
  logic. Self-healing, like the radar's "agent forgets to lapse" stance.
- Pruned by `prune_state` at a constant 500 lines (it holds one row per
  flagged silence; it cannot meaningfully grow).

### The injection (weekly only, `monitor.sh`)

A `QUIET ENTITIES` block alongside `$FEEDBACK_NOTE`/`$HORIZON_NOTE`, built the
same way (fail-safe `|| true`, skipped when empty/`python3` missing). Rules
given to the agent:

- For each row, check **this run's sweep first**: if the entity did the thing
  (or announced why it won't), record the observation as usual and do NOT
  flag — the arithmetic ran on last week's data and you hold newer evidence.
- Genuinely quiet → a **Quiet on** entry: the numbers from the row (the
  baseline is the credibility of the finding), the last event linked as the
  citation, your interpretation, and a confidence label. The *absence* is the
  sourced fact here; the interpretation is yours and must be marked as such.
- A quiet flag never justifies surfacing an unrelated marginal item, and an
  empty weekly stays empty — like the radar, this **adds to** a report, it
  never causes one. (If the weekly has no report and quiet entities exist,
  they wait; the portal dossier already shows the state.)

### Portal

`entity_inner()` (`bin/portal.py`) already renders each dossier's event
timeline; add one computed **Cadence** line above it reusing the same
median-gap arithmetic (shared via a small function imported from
`cadence.py` — `portal.py` already lives beside it in `bin/`). Quiet entities
get a `⚠ Nd quiet` tag built from glyph bytes at runtime per the ASCII-source
rule. Included in nothing else: no Overview card in v1 (the weekly + dossier
cover it; an Overview card is listed under v2).

### Config knobs (all optional, defaulted, stderr note when defaulted)

| Knob | Default | Meaning |
|---|---|---|
| `tracking.quiet` | `true` (when `tracking.enabled`) | compute + inject cadence silences; `false` disables everything |
| `tracking.quiet_factor` | 3 | flag at this multiple of the median gap |
| `tracking.quiet_min_events` | 4 | minimum events on record before an entity has a "norm" |

The 14-day floor and the 500-line flag prune stay constants.

### `bin/cadence.py` (new, stdlib only)

Modes, following the `horizon.py` pattern:

- `quiet --as-of YYYY-MM-DD [--factor F] [--min-events N] OBSERVATIONS [QUIET_STATE]`
  — emit the quiet rows (JSONL) after suppression.
- `mark --as-of YYYY-MM-DD QUIET_STATE` — append flag rows for the quiet rows
  read on stdin (called by `monitor.sh` post-report).
- Malformed lines skipped and counted to stderr; missing files emit nothing;
  unparseable timestamps skip the row rather than crash.

### monitor.sh sketch

```sh
# next to the HORIZON_NOTE block (weekly only):
QUIET_NOTE=""; QUIET_ROWS=""
if [ "$MODE" = weekly ] && [ -n "$QUIET_ENABLED" ] && [ -s state/observations.jsonl ] \
   && command -v python3 >/dev/null 2>&1 && [ -f bin/cadence.py ]; then
  QUIET_ROWS="$(python3 bin/cadence.py quiet --as-of "$TODAY" \
      --factor "$QUIET_FACTOR" --min-events "$QUIET_MIN_EVENTS" \
      state/observations.jsonl state/quiet.jsonl 2>/dev/null || true)"
  [ -n "$QUIET_ROWS" ] && QUIET_NOTE="

QUIET ENTITIES - cadence baselines. ... (rules above) ...
\`\`\`jsonl
$QUIET_ROWS
\`\`\`"
fi
# ...$QUIET_NOTE appended next to $HORIZON_NOTE...

# after the report is promoted (weekly only): remember what was flagged
if [ -n "$QUIET_ROWS" ]; then
  printf '%s\n' "$QUIET_ROWS" \
    | python3 bin/cadence.py mark --as-of "$TODAY" state/quiet.jsonl 2>/dev/null \
    || echo "[monitor:$MODE] note: quiet-flag bookkeeping failed (harmless)" >&2
fi
```

### Failure modes (warn-only; the run and report are never at risk)

| Failure | Behavior |
|---|---|
| `tracking.quiet: false` / `tracking.enabled: false` | no computation, no injection, no dossier line |
| too few events per entity | entity simply has no baseline; never flagged |
| corrupt observation/flag rows | skipped by `cadence.py`, counted to stderr |
| `python3` missing | note, skip (the prompt's existing Quiet on guidance still applies) |
| agent flags despite fresh activity | the prompt forbids it; worst case is one redundant line, corrected next run when `mark`'s flag suppresses it |
| `mark` fails | same silence re-flags next weekly — annoying, not wrong |
| entity intentionally seasonal | `quiet_factor` is the user's lever; a thumbs-down on the finding feeds calibration like any other grade |

## Tests (`tests/run.sh`; claude is stubbed)

1. **Baseline math** via direct `cadence.py quiet` invocation: 9 seeded events
   at ~21-day gaps with `last_seen` 56 days back → one quiet row with
   `median_gap_days` 21; the same entity 20 days quiet → no row; an entity
   with 3 events → no row (`quiet_min_events`).
2. **Floor:** a 2-day-cadence entity 10 days quiet → no row (14-day floor).
3. **Suppression:** `mark` the quiet row, re-run `quiet` → empty; append a
   newer observation (last_seen advances) and age it past the threshold →
   flags again as a new episode.
4. **Injection:** weekly run with a seeded quiet entity → the captured prompt
   contains a `QUIET ENTITIES` block with that entity; a daily run does not.
5. **Silence preserved:** weekly with quiet entities but an empty report →
   still no report.
6. **Disabled:** `tracking.quiet: false` → no block, no `quiet.jsonl` writes.
7. **Corrupt rows** in observations/flag files skipped without aborting.
8. **Portal:** dossier shows the Cadence line; a quiet entity shows the tag.
9. `shellcheck` on touched shell; `python3 -m py_compile bin/cadence.py`.

## Cost

Zero additional claude passes; the weekly prompt grows by a few rows. The
agent may spend a turn or two of its existing weekly budget double-checking a
flagged entity — which is exactly the verification the Quiet on section always
implied but never had the data to direct.

## Out of scope / v2 ideas

- **Mention-volume baselines** — needs sweep-effort normalization first, or
  it measures our coverage, not their silence.
- **Overview card** — a "Quiet" card beside Coming up; deferred until the
  weekly section proves the signal is worth screen space.
- **Horizon unification** — emit each computed baseline as an *implicit*
  expectation in `horizon.jsonl` so one mechanism carries stated and derived
  dates; rejected for v1 because implicit rows would pollute a file whose
  every row is currently a sourced, stated fact.
- **Cadence-aware sweep attention** — a quiet entity's sources get extra
  sweep attention that run (cheap prompt line; bundled here if trivial,
  otherwise its own follow-up).
