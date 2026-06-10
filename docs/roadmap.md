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
- The **web portal** (`bin/portal.sh`/`portal.py`) presents the Overview (tracked
  entities + latest metric + sparkline, recent events, recent runs), plus Reports,
  Review, and read-only Profile/Config; `bin/portal.py --export` writes a static
  **`kb/index.html`** snapshot each run, toggled by `output.dashboard`.

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
- The portal's **Review** tab (`bin/portal.py`) lists recent surfaced items with
  👍 / 👎 buttons; a click records the grade + item context to `state/feedback.jsonl`.
  Localhost-only — reach it over an SSH/VS Code forward.
- The next `bin/bootstrap.sh` reads `feedback.jsonl` as ground-truth calibration and
  tunes `relevance.rubric` / `relevance.calibration` to match (no fragile in-place
  YAML mutation; you still review/approve the draft).

## Phase 5 — presentation + editorial polish ✅ (shipped)

Make the delivered report look and read like a designed brief, not a data dump:
- A redesigned email/HTML template (`wrap_html` in `bin/email-lib.sh`): a header card
  (subject + "Daily/Weekly briefing — date"), a hidden inbox preheader, a bottom-line
  callout, uppercase section dividers, a styled watchlist table with sparklines, and a
  footer. Table-based layout with bgcolor + inline styles so it holds up in Outlook as
  well as Gmail/Apple Mail. Deterministic (no per-run LLM cost), ASCII-only source. No
  external assets; an optional brand logo (`output.email_images`) rides along as a
  CID-embedded inline image, never a remote fetch. Reports are authored as Markdown so
  they render as the brief and stay readable as plain text.
- An optional **editorial pass** (`models.editor`, `editor-prompt.md`): a dedicated
  editor curates + polishes the report before delivery (lead, order, cut/merge,
  tighten) — strictly editorial (no new facts, figures unchanged, citations kept; no
  web/Bash tools), non-destructive (restores the unedited report on failure/empty),
  and logged to `runs.log` as `pass: editor`. Opt-in and runs only on delivered days.

## Phase 6 — bootstrap delivery ✅ (shipped)

Turn bootstrap's output into the first intelligence deliverable and lower the friction
on the review gate:
- The research pass also writes `profile.draft.summary.md` — a human-readable digest
  (bottom line, market map, key players, anchor, rubric highlights, low-confidence
  flags to check).
- When `output.email_to` is set, `bootstrap.sh` emails that summary as a "profile draft
  ready for review" message (optionally editor-polished first via `models.editor`). It's
  a review *aid* — approval stays the deliberate local `cp profile.draft.yaml
  profile.yaml`, which the email spells out. Opt-in and fail-safe (a send/edit failure
  never loses the on-disk draft).
- Extracted the shared `bin/config-lib.sh` (cfg readers) and `bin/email-lib.sh`
  (rendering + `send_email`) so monitor and bootstrap share one implementation (and
  bootstrap drops its bespoke, drift-prone config parser).

## Phase 7 — live calibration ✅ (shipped)

Close the lag between grading an item and the grade changing anything. Each monitor
run injects the newest **post-bootstrap** grades from `state/feedback.jsonl` (latest
verdict per item via `dedupe-feedback.py --since <last_bootstrapped> --max N`) into
the triage prompt as worked examples — a thumbs-down filters its lookalikes the next
run. Capped by `relevance.recent_grades` (default 20, `0` = off); grades older than
the approved profile are excluded because the rubric already absorbed them at
bootstrap. Fail-safe: any problem skips the injection, never the run.

## Phase 8 — precision tracking ✅ (shipped)

Prove (or disprove) "it gets sharper as you grade" with data the system already has.
The portal Overview gains a **Calibration** card, built by joining
`state/feedback.jsonl` (latest verdict per item) to `state/seen.jsonl` (surfaced
items): 30-day **precision over graded items only** — an ungraded item is unknown,
not an implicit positive — with **grading coverage** alongside to keep the headline
honest, a precision-by-week SVG on the same time axis as the other Activity charts,
and **per-source hit rates** (surfaced / graded / thumbs-up rate) to show which
sources earn their rank before the next bootstrap re-ranks them. Stdlib-only,
server-rendered, omitted until the first grade exists.

## Phase 9 — webhook delivery ✅ (shipped)

A second delivery channel so reports can land where a team sees them. Set
`output.webhook_url` and each delivered report is POSTed there as one JSON object
(`bin/webhook.py`, stdlib only). The payload is polyglot — `text` for Slack incoming
webhooks, `content` (2000-char-truncated) for Discord, `title`/`mode`/`date`/
`report_markdown` for generic receivers — so one URL works across services. Parallels
the email path exactly: opt-in via config, fail-safe (a failed post warns; the run
succeeds and the report is already in `kb/`), same report content.

## Phase 10 — entity dossiers ✅ (shipped)

Reports are perishable; what's *known* about an entity should compound. The portal
gains an **Entities** tab: an index of every entity on file (observed in
`observations.jsonl` or tagged on a surfaced item) and a dossier page per entity —
its metric series with sparklines, its event timeline, and every surfaced item that
concerned it (with grade verdicts where given). Surfaced item records now carry an
`entities: [...]` tag (exact names from `tracking.watch` + the profile watchlist, see
`monitor-prompt.md`); pre-tagging records still land in dossiers via a
case-insensitive title/so_what name match. Entity names on the Overview link to their
dossiers; the static export keeps plain text (it has no `/entity` route).

## Phase 11 — deterministic feed sweep ✅ (shipped)

Make recall auditable instead of hoped-for. Bootstrap now also emits
`subject.derived.feeds` — verified RSS/Atom URLs for the ranked sources that have
them. Each monitor run starts with `bin/fetch.py` (stdlib only) pulling those feeds
deterministically: entries inside the lookback window (daily = `lookback_hours`,
weekly = 7 days + overlap), not already in `seen.jsonl`, deduped across feeds, capped
at `monitoring.fetch_max_items` (default 200, `0` disables). The candidates land in a
scratch JSONL the triage prompt names as *the* sweep of those feeds — score first,
don't re-fetch — so the agent's own bounded browsing covers only feedless sources
(the recall backstop; "feeds-first + agentic backstop"). A broken feed is a warning,
never a failed run; with no feeds configured the monitor behaves exactly as before.

## Phase 12 — run budgets ✅ (shipped)

Make the cost levers explicit config instead of constants buried in the scripts. A
top-level `budgets:` block sets the per-pass turn caps handed to each `claude
--max-turns` call (`bootstrap_max_turns` 80, `monitor_max_turns` 40,
`deepdive_max_turns` 40, `editor_max_turns` 15 — defaults match the values the
scripts always used), plus an opt-in **soft monthly cap**: when
`budgets.monthly_cost_usd` > 0 and the rolling 30-day sum of `cost_usd` in
`state/runs.log` crosses it, every monitor run warns on stderr. Warn-only by design
— the figure is an API-equivalent estimate, not subscription billing, and silently
stopping the watch would cost more than it saves. Absent/`0`/non-numeric knobs fall
back to the defaults; a missing `jq` skips the cost check with a note, never the run.

## Phase 13 — guided config interview ✅ (shipped)

Lower the biggest adoption barrier: output quality depends entirely on a well-written
`monitor-config.yaml`, and new users shouldn't have to write YAML cold. `bin/init.sh`
is a deterministic bash wizard (plain `read` prompts — no model in the loop, fully
offline-capable) that collects the human-authored fields — closest-fit template
(any `samples/` config or the blank-slate example), subject name/description, seed
URLs, scope in/out, anchor name/type/relationship, competitors,
`output.email_to`/`webhook_url`, `deployment.instance` — and substitutes them into
the chosen template, preserving its comments and empty `derived:` blocks (never
generating YAML from scratch). Validates as it goes: http(s) seed URLs, and every
answer must round-trip exactly through the repo's `cfg_get`/`cfg_get_text` readers
(correct YAML quoting for `&` / `'` / `"` / `#`). One optional `claude -p` review at
the end (model `models.init`, inheriting `models.bootstrap`, then the CLI default;
capped by `budgets.init_max_turns`, default 15) only *suggests* — sharper scope,
better seeds, missed competitors — shown as a diff and applied only on an explicit
yes; a failed/empty/invalid suggestion never loses the assembled draft. Refuses to
overwrite without `--force`, assembles in a temp file and moves it into place
atomically, and offers (never auto-runs) `bootstrap.sh` at the end.

## Phase 14 — missed-signal capture ✅ (shipped)

The recall side of calibration. Thumbs can only grade what WAS surfaced, so the
precision headline (Phase 8) can't see a false negative — and "silence beats noise"
makes misses invisible by design. The portal's Review tab gains a **"Report a missed
signal"** box: paste the URL of something the monitor should have caught (plus an
optional why-it-mattered note) and it's recorded to `state/feedback.jsonl` with
verdict `missed` (stable per-URL id, so a re-report collapses to one row). Missed
reports ride the existing two calibration clocks unchanged: live calibration injects
them on the very next run (treat lookalikes as in-scope; give that source sweep
attention), and the next bootstrap tunes the rubric AND the source ranking/feeds so
items like it get swept at all. The Calibration card counts reported misses beside
the precision figure to keep the headline honest.

## Phase 15 — profile-refresh diff ✅ (shipped)

The durable half of the learning loop ("grades consolidate at the next bootstrap")
hinged on a review nobody is helped through: re-reading a whole profile. Make the
refresh gate a 2-minute skim instead:
- On a re-bootstrap (an approved `profile.yaml` exists), `bootstrap.sh` writes
  **`profile.draft.diff`** — a unified diff of the draft vs the approved profile —
  and folds it into the "draft ready for review" email as a *What changed vs the
  approved profile* section (truncated past 200 lines; appended after the editorial
  pass so the editor can never touch it). First run / identical draft / no `diff`
  tool → a note, never a failure.
- The portal's draft view (`/profile?draft=1`) leads with the same diff, computed
  live via `difflib` so it can't go stale; the awaiting-review banner links to it.
- Approval stays the deliberate local `cp` — this lowers the cost of the gate, it
  doesn't move it.

## Phase 16 — coverage integrity ✅ (shipped)

Two small guards that keep the sweep's coverage from silently rotting:
- **Feed health.** `bin/fetch.py --health` (passed by the monitor) persists per-feed
  sweep health to `state/feedhealth.json`: last success, consecutive failures, and
  the newest entry ever seen. A feed failing 3+ runs in a row warns loudly in the
  run log, and the portal Overview gains a **Feed health** card — failing feeds
  (with their streak), stale feeds (HTTP 200 but nothing new in 14+ days — dead by
  another name), then healthy ones. Feeds dropped from the profile are pruned;
  everything stays warning-only and stdlib-only.
- **Catch-up lookback.** A slept-through or skipped run used to lose its window
  forever — the next run still looked back only `lookback_hours`. Now, when the
  last logged run (newest `state/runs.log` row) is older than this run's window,
  the window widens to cover the gap — applied to both the feed pre-sweep and the
  agent's own browsing (a `CATCH-UP WINDOW` prompt note) — by at most
  `monitoring.catchup_max_hours` *extra* hours on top of the normal window (default
  168, `0` disables; bounding the widening rather than the window lets weekly runs
  catch up too) so a long-dormant deployment can't trigger an unbounded sweep.

## Phase 17 — multi-recipient email ✅ (shipped)

`output.email_to` is no longer a single address. A new `cfg_get_list` reader in
`bin/config-lib.sh` parses it as either a scalar (back-compat), a comma-joined string,
or a YAML list:
```yaml
output:
  email_to:
    - you@example.com
    - teammate@example.com
```
The monitor and bootstrap collect the addresses into an array; `send_email` comma-joins
them for the `To:` header and passes each as its own `msmtp` envelope recipient (fixing
the old `msmtp "$to"` that would have mishandled more than one). Existing single-address
configs are untouched. (The `output.distribution` block stays documentation-only — this
covers the email fan-out people actually asked for, without the multi-channel machinery.)

## Backlog / possible next steps (not started)

Ideas raised but not built — captured so they aren't lost:

- **Rubric backtest at the refresh gate** *(designed — see
  [`design-rubric-backtest.md`](design-rubric-backtest.md))*. The refresh review
  sees what changed in the draft (Phase 15) but not what *effect* it has. Replay
  the user's graded items (`state/feedback.jsonl`) against the draft rubric —
  blind, on the monitor model, numbers computed deterministically — and fold an
  agreement report ("87% vs your verdicts; would now drop these 2 thumbs-ups")
  into the review email and the portal draft view. Turns the approval gate from
  "does this YAML read right?" into "does this rubric demonstrably agree with my
  judgment more than the approved one?"
- **Dog-that-didn't-bark detection.** `observations.jsonl` encodes each entity's
  normal cadence; an entity gone quiet well past its baseline is itself a finding
  ("no release in 8 weeks vs a 3-week norm"). Deterministic from existing state.
- **Confidence-label resolution.** Items ship with high/medium/low confidence but
  nothing checks whether high-confidence calls pan out more often than low ones;
  even a crude sampled follow-up would tell us if the labels mean anything.
- **Thread-friendly email subject.** Gmail collapses daily reports into one
  conversation because the subject prefix is stable. Option to lead the subject with
  the date or market (e.g. `<market> — daily <date>`) or add a per-run token so each
  report threads separately. (Or just turn off Gmail conversation view — a zero-code
  workaround.)
- **Tailor `docs/overview.md`** — swap the generic "Example Market"/Acme example for a
  real market + competitors if showing it to a specific audience.
