# CLAUDE.md — working notes for this repo

Conventions to keep when changing **Vantage Point** (an autonomous market-intelligence
agent). Read this first; it encodes decisions made across the build so a fresh session
stays consistent instead of re-deriving them.

- **What it is / docs map:** [`README.md`](README.md) is the operator runbook,
  [`docs/overview.md`](docs/overview.md) is the plain-language explainer,
  [`docs/roadmap.md`](docs/roadmap.md) tracks shipped phases + a backlog.

## Architecture (one config, two agents)

- **bootstrap** (`bin/bootstrap.sh` + `bootstrap-prompt.md`): one-time deep research →
  writes `profile.draft.yaml`; a human promotes it to `profile.yaml` (the review gate).
- **monitor** (`bin/monitor.sh` + `monitor-prompt.md`): scheduled daily/weekly run —
  sweep → dedup → score → trends → optional deep-dive → report → deliver.
- **deep-dive** (`deepdive-prompt.md`): optional 2nd pass (`models.deepdive`) that
  corroborates the top items on a stronger model.
- Both are `claude -p` calls wrapped in shell. Helpers: `dashboard.sh` (→ `kb/index.html`),
  `review.sh`/`feedback-server.py` (grading UI → `state/feedback.jsonl`), `usage.sh`,
  `install-launchd.sh`, `dedupe-feedback.py`.
- **State** (gitignored): `state/seen.jsonl` (dedup), `state/observations.jsonl`
  (trends), `state/feedback.jsonl` (grades); `kb/` (reports + dashboard).
- Deployed on a macOS mini via **launchd**, running from a local checkout — changes
  reach it by `git pull`, not by merging to GitHub. `install-launchd.sh` regenerates the
  plists and retires old agents.

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
  never a crash. Example values live in `monitor-config.example.yaml`.
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
