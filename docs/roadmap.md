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

## Phase 3 — two-pass deep dive ✅ (shipped)

Triage on the `monitor` model queues its top survivors (`monitoring.deepdive_threshold`,
capped at `deepdive_max_items`); when `models.deepdive` is set, a second pass on the
stronger model investigates each — fetches the primary source, **corroborates across
independent sources** (downgrades/flags rumors), and deepens the so-what with
`observations.jsonl` history — then enriches those entries in the report in place
(`deepdive-prompt.md`). Opt-in (remove `models.deepdive` to stay single-pass) and
cost-bounded (fires only on high-scorers, capped per run); both passes are logged to
`runs.log` with a `pass` field.

## Phase 4 — one-click calibration ✅ (shipped, clickable-web variant)

Make grading frictionless so the rubric learns your taste and quality compounds:
- Stable per-item `id` in every report/state record.
- `bin/review.sh` serves a localhost grading UI (`bin/feedback-server.py`) listing
  recent surfaced items with 👍 / 👎 buttons; a click records the grade + item context
  to `state/feedback.jsonl`. Localhost-only — reach it over an SSH/VS Code forward.
- The next `bin/bootstrap.sh` reads `feedback.jsonl` as ground-truth calibration and
  tunes `relevance.rubric` / `relevance.calibration` to match (no fragile in-place
  YAML mutation; you still review/approve the draft).

## Backlog / possible next steps (not started)

Ideas raised but not built — captured so they aren't lost:

- **Second delivery channel.** A Slack / Discord / Telegram (or generic webhook)
  delivery option, so `output.distribution` becomes real instead of documentation.
  Would parallel the email path: opt-in via config, fail-safe (never breaks the run),
  same report content.
- **Thread-friendly email subject.** Gmail collapses daily reports into one
  conversation because the subject prefix is stable. Option to lead the subject with
  the date or market (e.g. `<market> — daily <date>`) or add a per-run token so each
  report threads separately. (Or just turn off Gmail conversation view — a zero-code
  workaround.)
- **Tailor `docs/overview.md`** — swap the generic "Example Market"/Acme example for a
  real market + competitors if showing it to a specific audience.
