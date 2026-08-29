# Design: confidence-label resolution

*Status: proposed (backlog — not started). Companion to the backlog entry in
[`roadmap.md`](roadmap.md).*

## Problem

Every surfaced item ships with a confidence label (`high` / `medium` / `low`),
and the honesty constraints lean on it hard: "mark confidence", "tag
low-confidence interpretations as such". The deep-dive pass adjusts it, the
trend detector labels with it, the reader is implicitly told to weight items
by it. **Nothing ever checks whether the labels mean anything.** If
high-confidence calls pan out no more often than low-confidence ones, the
label is decoration — and a reader who trusts it is being miscalibrated by the
very mechanism that's supposed to keep the report honest.

The system already proves precision claims with data it has (Phase 8 joins
`feedback.jsonl` to `seen.jsonl`); confidence is the same shape of question
with one missing ingredient: an after-the-fact verdict on whether the item's
claim **held up**. A thumbs-up can't stand in for it — grades measure
*relevance* ("right to surface"), not *accuracy* ("the rumor was true"). As
the backlog puts it: even a crude sampled follow-up would tell us if the
labels mean anything. This design is that crude sampled follow-up.

## What the reader sees

**Portal** — the Calibration card (Phase 8) gains a **Confidence resolution**
table, omitted until the first resolution exists:

```
Confidence resolution (sampled follow-ups, all time)

  label    sampled   held   busted   unclear   held rate
  high          14     11        1         2        92%   (of the clear calls)
  medium         9      6        2         1        75%
  low            7      2        3         2        40%
```

The payoff is the *ordering*: high > medium > low held-rates mean the labels
carry information; a flat or inverted table means they don't, and the rubric /
prompts need work. Either answer is worth having.

**Reports** — nothing in v1. A miscalibrated label table is an operator
finding, not an anchor finding; it belongs on the portal next to precision,
not in the brief. (A weekly callout when the ordering inverts is a v2 idea.)

## Design

### Architecture (rides the weekly run; no new pass)

```
state/seen.jsonl (surfaced items, with confidence + date — existing)
  |        state/resolutions.jsonl (already-resolved ids excluded)
  | bin/resolution.py sample --as-of TODAY --min-age-days 28 --max N
  v                       (deterministic: aged, stratified sample)
RESOLUTION CHECKS prompt block (weekly run only)
  |   agent re-checks each item against today's web:
  |   held / busted / unclear (+ evidence URL)
  v
state/resolutions.jsonl  (append-only, latest-per-id)
  |
  v
portal Calibration card: per-label held rates (deterministic arithmetic)
```

The standard split: the **sampler and the arithmetic are deterministic**
(`bin/resolution.py`, stdlib); the **verdict needs judgment and fresh
evidence**, so it rides the weekly triage pass — bounded to a handful of
items, the same economics as the deep-dive cap.

### Sampling (`resolution.py sample`)

- Universe: surfaced records in `seen.jsonl` (full records — they carry
  `confidence`, `so_what`, `url`, `date`) whose `date` is at least
  `min_age_days` old (default 28 — younger items haven't had time to resolve)
  and whose `id` has no row in `resolutions.jsonl` yet.
- **Stratified by label**: round-robin across `high` / `medium` / `low`,
  newest-eligible-first within each, up to `tracking.resolution_sample` items
  per run (default 2). Without stratification the sample tracks the label
  distribution and `low` — the label we most need to test — never accumulates
  enough resolutions to read.
- Deterministic given the same state (no RNG): newest-first is reproducible,
  testable, and biases toward items whose context the operator still
  remembers, which makes spot-auditing the verdicts feasible.

### The verdict (weekly triage, bounded)

The injected block lists each sampled item (`id`, `title`, `url`, `so_what`,
`confidence`, `date`) and instructs the agent, per item, to spend at most a
search or two answering one question: **did the item's claim/implication hold
up?**

- `held` — the event was real / the implied development materialized / no
  retraction or contradiction found *and* later coverage corroborates.
- `busted` — retracted, contradicted, or the implied development demonstrably
  didn't happen.
- `unclear` — can't tell cheaply. **Explicitly legitimate**: forcing a binary
  verdict would corrupt the table this feature exists to build. Unclear rows
  are counted but excluded from the held-rate denominator.
- Append one row per item to `./state/resolutions.jsonl`; never edit the
  report because of a resolution (a busted item from five weeks ago is
  calibration data, not news — unless it independently clears this run's bar,
  in which case it surfaces on its own merits).

Resolution record (append-only, latest-row-per-id like `feedback.jsonl`):

```json
{
  "timestamp": "2026-06-15T07:00:00Z",
  "id": "a1b2c3d4",                  // the surfaced item's id (joins seen.jsonl)
  "verdict": "held",                  // held | busted | unclear
  "confidence": "high",               // carried from the item, so the table
                                      // survives seen.jsonl pruning
  "evidence": "https://...",          // REQUIRED for held/busted; null for unclear
  "note": "GA confirmed on vendor blog, two weeks late"
}
```

No evidence, no verdict — `held`/`busted` without a citation degrades to
`unclear` at render time (the honesty rule, enforced in arithmetic).

### Rendering (portal)

`calibration_card()` in `bin/portal.py` gains the table: collapse
`resolutions.jsonl` latest-per-id (the existing `_latest_feedback()` pattern),
group by `confidence`, compute held rates over clear calls only, with
`unclear` shown so the denominator is honest. Included in the static export
like the rest of the card. Stdlib, server-rendered, omitted when the file is
missing/empty.

### Config knobs (all optional, defaulted, stderr note when defaulted)

| Knob | Default | Meaning |
|---|---|---|
| `tracking.resolution_sample` | 0 (off) | items re-checked per weekly run; opt-in |
| `tracking.resolution_min_age_days` | 28 | minimum item age before it's eligible |
| `tracking.resolutions_max_lines` | 2000 | prune bound for `state/resolutions.jsonl` |

**Opt-in by default** (like deep-dive and editor): the checks spend web turns
inside the weekly budget, and the table only becomes readable after weeks of
accumulation — a user should choose that spend. `monitor-config.example.yaml`
documents it next to the other `tracking` knobs.

### monitor.sh sketch

```sh
# next to the QUIET/HORIZON note blocks (weekly only; sample > 0):
RESOLUTION_NOTE=""
if [ "$MODE" = weekly ] && [ "$RESOLUTION_SAMPLE" -gt 0 ] && [ -s "$STATE_FILE" ] \
   && command -v python3 >/dev/null 2>&1 && [ -f bin/resolution.py ]; then
  SAMPLE="$(python3 bin/resolution.py sample --as-of "$TODAY" \
      --min-age-days "$RESOLUTION_MIN_AGE" --max "$RESOLUTION_SAMPLE" \
      --seen "$STATE_FILE" state/resolutions.jsonl 2>/dev/null || true)"
  [ -n "$SAMPLE" ] && RESOLUTION_NOTE="

RESOLUTION CHECKS - confidence calibration. ... (rules above) ...
\`\`\`jsonl
$SAMPLE
\`\`\`"
fi
```

Plus `prune_state state/resolutions.jsonl "$RESOLUTIONS_MAX_LINES"` beside the
other prunes.

### Failure modes (warn-only; the run and report are never at risk)

| Failure | Behavior |
|---|---|
| `resolution_sample: 0` (default) | nothing happens anywhere |
| no eligible items (young deployment) | sampler emits nothing; no block |
| agent skips some/all sampled items | they stay unresolved and are simply re-sampled on a later run — self-healing, no bookkeeping |
| agent writes a verdict with no evidence | render degrades it to `unclear` |
| corrupt rows | skipped by `resolution.py`/portal, counted to stderr |
| `python3` missing | note, skip injection |
| item's URL now dead | that's `unclear` (or `busted` if a retraction is findable) — exactly the rot [`design-evidence-preservation.md`](design-evidence-preservation.md) addresses; the two features compose but don't depend on each other |

## Tests (`tests/run.sh`; claude is stubbed)

1. **Sampler math** via direct invocation: seed surfaced items across the
   three labels and ages; assert stratification (one per label before a second
   of any), the age floor, the cap, exclusion of already-resolved ids, and
   determinism (two runs, identical output).
2. **Injection:** weekly run with eligible items and `resolution_sample: 2` →
   captured prompt contains a `RESOLUTION CHECKS` block with exactly 2 items;
   daily run → no block; default config → no block.
3. **Render math:** seed `resolutions.jsonl` (incl. one evidence-less `held`)
   → Calibration card shows per-label counts, held rate excludes `unclear`,
   and the evidence-less row counts as `unclear`.
4. **Re-sampling:** an item sampled but never resolved reappears in the next
   sample; a resolved one never does.
5. **Pruning** honored at `resolutions_max_lines`; corrupt rows skipped.
6. `shellcheck` on touched shell; `python3 -m py_compile bin/resolution.py`.

## Cost

Opt-in. When on: ~2 extra item checks inside the existing weekly
`budgets.monitor_max_turns` (a search or two each — comparable to the
attention two extra candidates get), zero new claude passes, stdlib
arithmetic. The cheapest possible answer to "do our confidence labels mean
anything", which is the point: a crude sampled follow-up beats no follow-up.

## Out of scope / v2 ideas

- **Weekly callout on inversion** — one deterministic line when low-confidence
  items out-resolve high; needs months of data before it could fire honestly.
- **Feeding the labels back** — once the table is trustworthy, inject it at
  bootstrap so the rubric's confidence guidance is tuned by evidence (the
  same consolidation path grades take).
- **Deep-dive cross-check** — items the deep-dive corroborated should `held`
  at a very high rate; a gap there audits the deep-dive pass itself.
- **Resolving trend findings** — "What changed" entries carry confidence too;
  they'd need a different eligibility rule (the claim is the delta, not an
  item) and are rarer, so v1 sticks to items.
