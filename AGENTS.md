# Vantage Point

Vantage Point is a dependency-light autonomous market-intelligence agent. A
one-time `bootstrap` research pass builds a profile for a subject market and an
anchor; a human reviews and promotes that draft. The recurring `monitor` then
collects public signals, scores them against the approved profile, records
longitudinal state, and writes daily/weekly briefings and optional deliveries.

## Commands

- setup: `chmod +x bin/*.sh tests/run.sh`
- test: `shellcheck bin/*.sh tests/run.sh && python3 -m py_compile bin/*.py && bash tests/run.sh`
- lint: `shellcheck bin/*.sh tests/run.sh` (the repository has no separate formatter or linter)
- build: none (the project is interpreted Bash/Python; CI performs syntax/compile checks)
- run: `./bin/monitor.sh daily` or `./bin/monitor.sh weekly` (requires a local `monitor-config.yaml` and approved `profile.yaml`)

The setup and static checks have been run in this checkout. The test suite is
the expected green check once the fixes in PR #77 land. CI also runs `bash -n`
over `bin/*.sh` and `tests/run.sh`; the CI definition is
[`.github/workflows/ci.yml`](.github/workflows/ci.yml). `python3` is the only language runtime; this checkout was
checked with Python 3.14.6. The scripts target macOS system Bash 3.2 and also
run on Linux. `jq` is needed by [`bin/usage.sh`](bin/usage.sh); `shellcheck`
is a development/CI tool, not a runtime dependency.

Other useful entry points:

- `./bin/bootstrap.sh` — research/build `profile.draft.yaml`; approve explicitly with `cp profile.draft.yaml profile.yaml`.
- `./bin/bootstrap.sh --if-stale` — scheduled refresh gate; `--resume` resumes deep-research scratch work.
- `./bin/portal.sh` or `./bin/portal.sh --port 8080` — localhost portal; `./bin/portal.sh --export` writes `kb/index.html`.
- `./bin/usage.sh [days]` — summarize `state/runs.log` (requires `jq`).
- `./bin/install-launchd.sh` / `./bin/install-launchd.sh uninstall` — install/remove macOS schedules without editing tracked files.

## Stack & layout

- Bash plus Python standard library only; no Python package manifest or third-party application libraries. YAML is read by small in-repo `awk` helpers, not a YAML library.
- [`monitor-config.example.yaml`](monitor-config.example.yaml) is the configuration template; live `monitor-config.yaml`, profiles, `state/`, and `kb/` are gitignored.
- [`bin/bootstrap.sh`](bin/bootstrap.sh) creates the reviewed profile, optionally using plan/facet/challenge passes; [`bin/monitor.sh`](bin/monitor.sh) performs daily/weekly triage.
- [`bin/config-lib.sh`](bin/config-lib.sh) reads the deliberately limited YAML subset; [`bin/email-lib.sh`](bin/email-lib.sh) renders and sends optional email.
- [`bin/fetch.py`](bin/fetch.py), [`bin/horizon.py`](bin/horizon.py), and [`bin/cadence.py`](bin/cadence.py) provide deterministic feed, forward-radar, and quiet-detection processing. [`bin/dedupe-feedback.py`](bin/dedupe-feedback.py), [`bin/backtest.py`](bin/backtest.py), and [`bin/research.py`](bin/research.py) support calibration and bootstrap.
- [`bin/portal.py`](bin/portal.py) is the stdlib localhost web portal and static exporter; [`bin/webhook.py`](bin/webhook.py) is optional JSON webhook delivery; [`bin/demo-bundle.sh`](bin/demo-bundle.sh) packages a data-bearing portal demo.
- Root `*-prompt.md` files are the prompts for bootstrap, monitor, deep dive, editor, and deep-research passes. [`launchd/`](launchd/) contains plist templates; [`tests/run.sh`](tests/run.sh) is the end-to-end shell test harness with stubs.
- [`docs/`](docs/) contains the plain-language overview, roadmap, and design records; [`assets/`](assets/) contains the logo.

## Conventions

- Keep scripts ASCII and compatible with macOS Bash 3.2. Shell scripts use `set -euo pipefail`, careful empty-array handling, and explicit `|| true` only where failure is intentionally tolerated.
- Use Bash/ubiquitous CLI tools and Python stdlib; do not add a YAML parser or other heavy dependency. Config options are optional and default with a stderr note rather than crashing.
- The monitor refuses to run without `profile.yaml`. Bootstrap writes a draft and never promotes it: approval is the human `cp` step.
- Optional deep-dive, editor, email, webhook, dashboard, feed-health, and deep-research stages are fail-safe and non-destructive; a failed optional stage must preserve a good report/draft.
- State is append-oriented JSONL and hand-editable. Readers skip malformed records; bounded logs are pruned or compacted. Monitor runs share `state/.lock`; concurrent runs skip, and stale locks are reclaimed.
- Reports are Markdown in `kb/`; empty daily/weekly runs are intentionally silent. Grades go to `state/feedback.jsonl`; post-bootstrap grades affect the next monitor run and are consolidated by the next bootstrap.
- The approved profile is a competitive-intelligence artifact and stays uncommitted. Webhook URLs, recipient data, profiles, and accumulated reports belong only in ignored runtime files.

## Factory

Durable factory state lives in `.factory/`. Load the `factory-protocol` skill
before factory work and use `/spec`, `/plan`, and `/factory` for the normal
specification-to-delivery flow.

## Gotchas

- `config-lib.sh` is intentionally a minimal indentation-based YAML scanner, not a general YAML parser. Avoid nested key-name collisions and YAML constructs outside the supported subset.
- `launchd` is macOS-only. The installer hashes the refresh slot and namespaces labels with `deployment.instance`; slug collisions are rejected. Linux deployments use cron instead.
- `claude` is an external CLI and must be on the PATH available to launchd/cron. `msmtp`, Markdown renderers (`pandoc`/`cmark-gfm`/`cmark`), `jq`, and `timeout`/`gtimeout` are optional; missing optional tools degrade with warnings.
- The portal binds to `127.0.0.1` only. Demo bundles contain live config/profile/state verbatim and must be treated as sensitive; they are not redacted.
- `profile.draft.yaml` is not reviewable merely because it exists: successful bootstrap writes `state/.draft-complete`. A failed refresh leaves the approved profile untouched.
- `tracking.horizon` and `tracking.quiet` are deterministic arithmetic around agent-written observations; they do not decide whether an expectation happened or whether silence is meaningful.
- `output.distribution` is documentation only. The wired delivery switches are `output.email_to` and `output.webhook_url`.
