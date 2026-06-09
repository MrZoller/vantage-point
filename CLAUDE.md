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
- **monitor** (`bin/monitor.sh` + `monitor-prompt.md`): scheduled daily/weekly run —
  deterministic feed pre-sweep (`bin/fetch.py`, from `subject.derived.feeds`) + live
  calibration injection (recent post-bootstrap grades, `relevance.recent_grades`) →
  sweep → dedup → score → trends → optional deep-dive → optional edit → report →
  deliver (email and/or `output.webhook_url` via `bin/webhook.py`).
- **deep-dive** (`deepdive-prompt.md`): optional 2nd pass (`models.deepdive`) that
  corroborates the top items on a stronger model.
- **editor** (`editor-prompt.md`): optional final pass (`models.editor`) that curates +
  polishes the report before delivery — non-destructive, no new facts, citations kept.
- Both are `claude -p` calls wrapped in shell, sharing `config-lib.sh` (cfg readers) and
  `email-lib.sh` (rendering + `send_email`). Each pass's `--max-turns` cap comes from
  the `budgets:` config block (defaults = the long-standing constants), which also holds
  the soft 30-day cost warning (`budgets.monthly_cost_usd`; warn-only, never skips a
  run). Helpers: `portal.sh`/`portal.py` (unified
  web portal — overview (incl. the Calibration precision card)/reports/entities
  (per-entity dossiers)/review/profile/config; grading → `state/feedback.jsonl`;
  `--export` → static `kb/index.html`), `fetch.py` (deterministic feed sweep →
  candidates JSONL), `webhook.py` (JSON report delivery), `usage.sh`,
  `install-launchd.sh`, `dedupe-feedback.py` (latest-per-id grades; `--since/--max`
  scope the monitor's live-calibration window).
- **State** (gitignored): `state/seen.jsonl` (dedup), `state/observations.jsonl`
  (trends), `state/feedback.jsonl` (grades), `state/runs.log` (per-run usage);
  `kb/` (reports + dashboard).
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
