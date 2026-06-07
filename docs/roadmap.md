# Roadmap — from monitoring to intelligence

Four upgrades that move the tool from a *new-&-relevant items filter* toward a
decision aid. They share one backbone: a **structured, longitudinal, entity-centric
state** (`state/observations.jsonl`). Once the monitor records observations over
time, trend detection reads them, the conveyance layer renders them, and calibration
feeds back into what's worth recording.

Each phase ships as its own PR, with tests and docs, like the rest of the project.

## The backbone: observations

`state/observations.jsonl` — one JSON object per line, append-only, pruned by line
count (`tracking.observations_max_lines`). Schema (see `monitor-prompt.md`):

```json
{ "timestamp": "...", "entity": "...", "metric": "secondary_price_usd",
  "value": 3200, "unit": "USD", "event_type": null, "source": "https://...",
  "note": "..." }
```

`value` is a number for metrics, or a short string for events (with `event_type`).
Entities to track = the approved profile (anchor watchlist + key players) plus any
pinned in `tracking.watch`. No source, no observation; one data point is not a trend.

## Phase 1 — trend / shift detection ✅ (shipped)

Record observations each run; flag a **What changed** finding when a metric crosses
`min_pct_change`, an entity hits `repeat_streak` events, or mentions spike past
`mention_spike_factor`. A flagged move is material on its own. Config: `tracking`
block. Sensitivity starts high (with confidence labels), tighten after calibrating.

## Phase 2 — conveyance overhaul ✅ (shipped)

Findings land as decisions, not a list:
- Each report opens with a **bottom line** (the one thing to read), then What
  changed, then items grouped by opportunity / threat / shift with *why → action →
  confidence*.
- The weekly digest adds a **Watchlist status** table with unicode **sparklines**
  (render in both plain text and HTML mail — more portable than SVG).
- `bin/dashboard.sh` regenerates a browsable **`kb/index.html`** each run (tracked
  entities + latest metric + sparkline, recent events, report links); `output.dashboard`
  toggles it.

## Phase 3 — two-pass deep dive

Cheap triage on the monitor model (Sonnet) → for items above a high bar, a deep
investigation on a stronger model: fetch the primary source, **corroborate across
2–3 sources** (kills rumor amplification), pull history/context. New knobs:
`models.deepdive` and a deep-dive score bar. Daily cost stays close to today's
because the deep pass runs only on the few survivors.

## Phase 4 — one-click calibration

Make grading frictionless so the rubric learns your taste and quality compounds:
- Stable per-item IDs in every report.
- `bin/grade.sh <date> <id> up|down ["why"]` — zero-infra, headless-friendly —
  appends to `relevance.calibration`; the rubric is re-derived on the next bootstrap.
- `mailto:` grade links in the HTML email that pre-fill a grade (no daemon).
  (A clickable web dashboard would need a small local server — out of scope unless
  wanted.)
