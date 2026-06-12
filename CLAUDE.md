# CLAUDE.md — working notes for this repo

Conventions to keep when changing **Vantage Point** (an autonomous market-intelligence
agent). Read this first; it encodes decisions made across the build so a fresh session
stays consistent instead of re-deriving them.

- **What it is / docs map:** [`README.md`](README.md) is the operator runbook,
  [`docs/overview.md`](docs/overview.md) is the plain-language explainer,
  [`docs/roadmap.md`](docs/roadmap.md) tracks shipped phases + a backlog.

## Architecture (one config, two agents)

- **bootstrap** (`bin/bootstrap.sh` + `bootstrap-prompt.md`): one-time deep research →
  writes `profile.draft.yaml` (+ a `profile.draft.summary.md`); a human promotes it to
  `profile.yaml` (the review gate). Optionally editor-polishes + emails the summary as a
  "draft ready for review" — a review aid, not the approval (that stays the local `cp`).
  On a refresh it also writes `profile.draft.diff` (draft vs approved) and folds it into
  the email; the portal draft view shows the same diff live (difflib). A refresh also
  runs a **rubric backtest** (`bin/backtest.py` + `backtest-prompt.md`): replay the
  user's graded items (`state/feedback.jsonl`) against the DRAFT rubric — blind, on the
  monitor model — and fold an agreement report (`profile.draft.backtest.md`) into the
  email after the diff + a portal draft card (model only scores; the numbers are
  deterministic). Fail-safe, opt-out via `relevance.backtest_max_items: 0`.
  **Deep-research mode** (opt-in via `models.researcher`): bootstrap fans the single
  research pass into Deep-Research's shape as separate `claude -p` passes — a **plan**
  pass (`research-plan-prompt.md`) writes `state/.research/plan.json`, validated/clamped
  by `bin/research.py validate-plan`; batched **facet** passes (`research-facet-prompt.md`,
  `budgets.research_parallel` at a time, per-facet `budgets.facet_timeout_seconds`) write
  cited notes to `state/.research/notes/<id>.md`; then today's `bootstrap-prompt.md`
  **synthesizes** from the notes manifest. Plus deterministic `fetch.py --verify` (every
  draft feed must serve a parseable feed → `profile.draft.feedcheck.md`) and an optional
  adversarial **challenge** pass (`research-challenge-prompt.md`, `models.challenge`,
  non-destructive → `profile.draft.challenge.md`) — both folded into the email + portal
  draft view. Unset `models.researcher` = today's single pass, byte-for-byte; every
  failure degrades to a stub note / single-pass, never a lost draft; `--resume` redoes
  only missing facets. Per-pass usage logged to `runs.log`
  (`research-plan`/`research-facet:<id>`/`bootstrap`/`challenge`); `budgets.thinking_tokens`
  exports `MAX_THINKING_TOKENS` for plan/synthesis/challenge. Design:
  [`docs/design-deep-research-bootstrap.md`](docs/design-deep-research-bootstrap.md).
- **monitor** (`bin/monitor.sh` + `monitor-prompt.md`): scheduled daily/weekly run —
  deterministic feed pre-sweep (`bin/fetch.py`, from `subject.derived.feeds`; records
  per-feed health to `state/feedhealth.json` via `--health`) + catch-up lookback (gap
  since the last logged run widens the window, capped by
  `monitoring.catchup_max_hours`) + live calibration injection (recent post-bootstrap
  grades, `relevance.recent_grades`) + forward-radar due-expectation injection
  (`bin/horizon.py due`, `tracking.horizon`) + (weekly) quiet-entity injection
  (`bin/cadence.py quiet`, `tracking.quiet`: entities silent past their median event
  cadence, for the agent to verify → "Quiet on"; flagged silences marked to
  `state/quiet.jsonl` only post-ship and only for entities the shipped report names,
  so they never re-alarm but an unreported silence re-injects; self-voiding on
  resumption) → sweep → dedup → score → trends →
  optional deep-dive → optional edit → report → (weekly) append a deterministic
  **Coming up** section (`bin/horizon.py upcoming`, post-editor so kb/email/webhook/portal
  all carry it) → deliver (email and/or `output.webhook_url` via `bin/webhook.py`).
- **deep-dive** (`deepdive-prompt.md`): optional 2nd pass (`models.deepdive`) that
  corroborates the top items on a stronger model.
- **editor** (`editor-prompt.md`): optional final pass (`models.editor`) that curates +
  polishes the report before delivery — non-destructive, no new facts, citations kept.
- Both are `claude -p` calls wrapped in shell, sharing `config-lib.sh` (cfg readers) and
  `email-lib.sh` (rendering + `send_email`; table-based HTML for Outlook; one private
  message per recipient; optional CID-embedded brand logo from `assets/logo-email.png`
  when `output.email_images` is on). The portal inlines the same mark as SVG. Each pass's `--max-turns` cap comes from
  the `budgets:` config block (defaults = the long-standing constants), which also holds
  the soft 30-day cost warning (`budgets.monthly_cost_usd`; warn-only, never skips a
  run). Helpers: `init.sh` (guided config interview — a deterministic bash wizard that
  substitutes answers into a chosen template (samples/ or the example), preserving
  comments + empty `derived:` blocks; one optional claude review at the end on
  `models.init` → fallback `models.bootstrap`, cap `budgets.init_max_turns`, whose
  suggestions apply only on explicit yes; `--force` to overwrite, atomic write),
  `portal.sh`/`portal.py` (unified
  web portal — overview (incl. the Calibration precision card)/reports/entities
  (per-entity dossiers)/review/profile/config; grading + missed-signal reports →
  `state/feedback.jsonl` (verdicts up/down/missed);
  `--export` → static `kb/index.html`; Overview also has the forward-radar **Coming up**
  card + per-dossier **Expected** list and **Cadence** line), `demo-bundle.sh`
  (package the portal runtime — `portal.py`/`portal.sh`/`cadence.py` — plus the live
  `monitor-config.yaml`/`profile.yaml`/`state/`/`kb/` into a portable `dist/` folder +
  `start-demo.sh` launcher for showing the portal off-site with just `python3`, no
  agent; `--out`/`--tar`/`--force`; bundles as-is, no redaction), `fetch.py`
  (deterministic feed sweep → candidates JSONL), `horizon.py` (forward radar:
  `due`/`upcoming` over `state/horizon.jsonl`, latest-per-id, precision-scaled grace;
  stdlib), `cadence.py` (quiet detection: `quiet`/`mark`/`compact` — median event-gap
  baselines over `state/observations.jsonl` (sourced events only), 14-day floor, flags
  in `state/quiet.jsonl`; stdlib; the portal loads it by path for the dossier Cadence
  line), `webhook.py`
  (JSON report delivery), `usage.sh`, `install-launchd.sh`, `dedupe-feedback.py`
  (latest-per-id grades; `--since/--max` scope the monitor's live-calibration window),
  `backtest.py` (refresh-gate rubric backtest: `prepare` blinds the graded eval set,
  `render` computes agreement vs verdicts; stdlib), `research.py` (deep-research:
  `validate-plan` clamps + slugifies the plan's facets, emits `id<TAB>goal<TAB>json`
  per line for the bootstrap shell loop; stdlib).
- **State** (gitignored): `state/seen.jsonl` (dedup), `state/observations.jsonl`
  (trends), `state/feedback.jsonl` (grades), `state/horizon.jsonl` (forward-radar
  expectations; append-only, latest-per-id, `tracking.horizon_max_lines`),
  `state/quiet.jsonl` (quiet-detection flags; latest-per-entity/event_type, compacted
  — never tail-pruned — past a constant 500-line bound), `state/runs.log` (per-run
  usage), `state/feedhealth.json` (per-feed sweep health),
  `state/.research/` (deep-research scratch: `plan.json` + `notes/<id>.md`, cleared each
  non-`--resume` run); `kb/` (reports + dashboard).
- Deployed on a macOS mini via **launchd**, running from a local checkout — changes
  reach it by `git pull`, not by merging to GitHub. `install-launchd.sh` regenerates the
  plists (substituting `__VP_ROOT__` + `__VP_LABEL__`) and retires old agents. Multiple
  instances on one machine = one clone each with a distinct `deployment.instance`, which
  namespaces the agent labels (`ai.zoller.vantagepoint.<instance>.{daily,weekly}`);
  unset = un-suffixed labels (single-deployment default).

## Conventions (please keep)

- **Dependency-light.** Bash + small, ubiquitous CLI tools (`jq`, coreutils) and
  **Python stdlib only**. Don't add language libraries or heavy deps. Config is parsed
  with the in-repo `cfg_get`/`cfg_get_text` awk helpers, not a YAML library.
- **Shell scripts stay ASCII.** Build any non-ASCII output (e.g. sparkline block glyphs)
  from bytes at runtime, so files diff cleanly in git and run on macOS's bash 3.2.
- **`set -euo pipefail`** in every script; guard empty-array expansion
  (`${arr[@]+"${arr[@]}"}`) and assignments so `set -e` can't abort unexpectedly.
- **Fail-safe & non-destructive.** Optional steps (deep-dive, email, dashboard) must
  never break the run or destroy a good report/state — back up and restore on failure.
- **Config knobs:** optional with sane fallbacks; absent/blank → default + a stderr note,
  never a crash. Example values live in `monitor-config.example.yaml`; ready-to-copy
  use-case configs (with empty `derived:` blocks) live in `samples/`.
- **Ethos:** *silence beats noise* (no empty-day spam); human review gate before the
  monitor trusts a profile; corroborate before surfacing; cite every item.
- **Docs honesty:** state default-vs-optional accurately; don't overclaim (privacy,
  corroboration, the learning loop all have real caveats — see `docs/overview.md`).

## Before every change

- Add or extend tests in **`tests/run.sh`** (it stubs `claude`/`launchctl`/`msmtp` so
  the non-`claude` logic is testable end-to-end).
- Keep clean: `shellcheck bin/*.sh tests/run.sh` and `python3 -m py_compile bin/*.py`,
  then `bash tests/run.sh`. CI (`.github/workflows/ci.yml`) runs all three.
- Ship as **one focused PR per change**. Expect a Codex review (often P2 findings); fix
  clear ones, reply, and resolve the threads.
