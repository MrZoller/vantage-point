# Vantage Point codebase map

Vantage Point is a small shell/Python orchestration layer around the external
`claude -p` CLI. It separates expensive profile research from cheap recurring
triage, and keeps deployment data outside git. [`README.md`](../README.md) is
the operator runbook; [`docs/overview.md`](overview.md) explains the product
without implementation detail; [`CLAUDE.md`](../CLAUDE.md) is the repository's
working contract.

## Top-level shape

- [`bin/`](../bin/) contains all executable orchestration and deterministic helpers.
- Root prompt files define the contracts supplied to Claude: [`bootstrap-prompt.md`](../bootstrap-prompt.md), [`monitor-prompt.md`](../monitor-prompt.md), [`deepdive-prompt.md`](../deepdive-prompt.md), [`editor-prompt.md`](../editor-prompt.md), and the plan/facet/challenge prompts.
- [`monitor-config.example.yaml`](../monitor-config.example.yaml) and [`samples/`](../samples/) define the supported configuration shape. The live config and generated artifacts are ignored by [`.gitignore`](../.gitignore).
- [`launchd/`](../launchd/) contains templates, not installed plists. [`tests/run.sh`](../tests/run.sh) exercises the shell/Python boundary with temporary checkouts and command stubs.
- [`docs/design-*.md`](.) records shipped feature designs and future designs; [`docs/roadmap.md`](roadmap.md) distinguishes shipped phases from backlog.
- [`assets/`](../assets/) holds the email PNG and portal SVG branding. [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs Linux and macOS checks.

## Runtime entry points and data flow

### Bootstrap / profile gate

[`bin/bootstrap.sh`](../bin/bootstrap.sh) reads `monitor-config.yaml` through
[`bin/config-lib.sh`](../bin/config-lib.sh), then invokes the configured
bootstrap model with [`bootstrap-prompt.md`](../bootstrap-prompt.md). It writes
`profile.draft.yaml`, a human-readable summary, and (on refresh) a diff against
`profile.yaml`; it never edits the approved profile. The monitor's hard gate is
the presence of `profile.yaml`.

With `models.researcher`, bootstrap becomes a plan → parallel facets → synthesis
pipeline. [`bin/research.py`](../bin/research.py) validates, clamps, and
slugifies the planner's JSON; facet notes live under `state/.research/notes/`.
Missing/failed facets become stub notes or trigger single-pass synthesis.
`--resume` preserves completed scratch notes. `models.challenge` adds a
non-destructive adversarial report. [`bin/fetch.py --verify`](../bin/fetch.py)
checks draft feeds as a review aid. On refresh, [`bin/backtest.py`](../bin/backtest.py)
can blind and re-score graded items against the draft rubric; deterministic
rendering compares it with the approved baseline.

The final completion marker, `state/.draft-complete`, is deliberately written
only after a complete draft. This distinguishes a reviewable draft from a
partial file after a kill or failed run. The operator promotes the result with
`cp profile.draft.yaml profile.yaml`.

### Monitor / report pipeline

[`bin/monitor.sh`](../bin/monitor.sh) accepts `daily` or `weekly`, acquires the
shared lock, resolves defaults, and refuses to proceed without the approved
profile. Its normal flow is:

1. Bound/prune state and calculate catch-up lookback from the last run.
2. Run [`bin/fetch.py`](../bin/fetch.py) over approved-profile/config `feeds:`.
   RSS/Atom candidates are normalized to UTC, deduplicated against the seen
   file, capped, and passed to the agent. Feed failures warn and do not fail the
   run; optional health persists in `state/feedhealth.json`.
3. Inject recent grades, due expectations from [`bin/horizon.py`](../bin/horizon.py),
   and (weekly only) quiet entities from [`bin/cadence.py`](../bin/cadence.py)
   into [`monitor-prompt.md`](../monitor-prompt.md). Claude browses remaining
   public sources, scores against the approved profile, writes observations and
   a candidate report.
4. If enabled, deep dive high scorers using [`deepdive-prompt.md`](../deepdive-prompt.md),
   then optionally edit with [`editor-prompt.md`](../editor-prompt.md). Failed or
   empty optional output rolls back to the prior good report.
5. Promote only a successful non-empty report to `kb/YYYY-MM-DD.daily.md` or
   `.weekly.md`. Weekly reports receive deterministic “Coming up” output from
   `horizon.py`. Email and webhook delivery happen after the report is safe on
   disk; delivery failures cannot lose it. The portal snapshot may be refreshed
   afterward.

An empty run intentionally emits `NO_MATERIAL_ITEMS` and no report. The lock is
PID/start-time aware where the platform provides `ps -o lstart`, and stale locks
are reclaimed rather than blocking future schedules forever.

## Core domain objects and storage

- **Subject / anchor / rubric:** YAML blocks in `monitor-config.yaml`; their
  derived, reviewed form is `profile.yaml`. The subject is the market; the anchor
  defines whose opportunity/threat/shift matters. See
  [`monitor-config.example.yaml`](../monitor-config.example.yaml).
- **Candidate item:** feed or agent-discovered signal, eventually represented
  in the seen JSONL with URL, score, signal, citations, and optional entity tags.
  The exact report record contract is specified in [`monitor-prompt.md`](../monitor-prompt.md).
- **Observation:** agent-written JSONL in `state/observations.jsonl`, keyed by
  entity/metric and used for trend deltas, streaks, spikes, and cadence. Metrics
  marked `event` with a source feed quiet detection; unsourced rows do not.
- **Feedback:** portal grades and missed signals in `state/feedback.jsonl`.
  [`bin/dedupe-feedback.py`](../bin/dedupe-feedback.py) selects latest verdicts
  by timestamp for calibration.
- **Expectation:** append-only `state/horizon.jsonl`; latest row per `id` wins,
  and met/lapsed/withdrawn statuses retire a pending expectation. Grace periods
  are fixed by precision in [`bin/horizon.py`](../bin/horizon.py).
- **Quiet episode:** [`bin/cadence.py`](../bin/cadence.py) computes median gaps
  over distinct sourced event dates, with a 14-day floor, and records reported
  episodes in `state/quiet.jsonl`. Compaction is by entity/event type, not tail
  pruning, so active flags survive.
- **Run accounting:** `state/runs.log` records Claude pass usage; [`bin/usage.sh`](../bin/usage.sh)
  sums it. `cost_usd` is an API-equivalent estimate, not subscription billing.
- **Outputs:** Markdown reports and portal snapshot live in `kb/`; optional
  email is rendered by [`bin/email-lib.sh`](../bin/email-lib.sh), and optional
  JSON delivery is handled by [`bin/webhook.py`](../bin/webhook.py).

## Portal architecture

[`bin/portal.sh`](../bin/portal.sh) is argument validation and launcher;
[`bin/portal.py`](../bin/portal.py) implements the stdlib
`ThreadingHTTPServer`, HTML views, static export, report rendering, and grade
POSTs. It serves Overview, Reports, Entities, Review, Profile, and Config. It
binds localhost only, uses inline SVG charts and logo, and has a built-in
Markdown fallback when no renderer is installed. [`bin/cadence.py`](../bin/cadence.py)
is imported by the portal so dossier cadence numbers match monitor arithmetic.
The portal reads runtime state defensively: malformed JSONL, non-scalar values,
bad timestamps, and missing files are skipped or rendered as absent rather than
bringing down the page.

[`bin/demo-bundle.sh`](../bin/demo-bundle.sh) copies the portal runtime plus
live config, profiles, state, and knowledge base into a separate bundle and
creates `start-demo.sh`; the bundle can run with Python alone and writes grades
to its own copied state.

## External dependencies and integration points

- **Claude CLI:** bootstrap, monitor, deep-dive, editor, init, and optional
  research passes use `claude -p`; authentication/model availability are outside
  this repository. Scheduled environments need an explicit PATH.
- **macOS launchd:** [`bin/install-launchd.sh`](../bin/install-launchd.sh)
  substitutes XML-escaped checkout paths and labels into plist templates,
  installs daily/weekly/refresh agents, and retires legacy labels. Linux uses
  cron as documented in the README.
- **jq:** only [`bin/usage.sh`](../bin/usage.sh) requires it. `msmtp` is optional
  email transport. `pandoc`, `cmark-gfm`, and `cmark` are optional Markdown
  renderers, selected in that order.
- **Network feeds:** Python stdlib `urllib` fetches HTTP(S) RSS/Atom feeds;
  redirect handling explicitly includes 308 for older Python versions. The
  Claude agent is the backstop for sources without feeds.
- **Webhook receivers:** `output.webhook_url` receives a polyglot payload with
  Slack `text`, Discord `content`, and generic metadata. Failed posts are
  warnings.

## Bodies buried / risks and oddities

- The YAML reader is intentionally not YAML-compliant. Complex quoting,
  multiline values, or a child key colliding with a key read under the same
  block can be misread; preserve the example's supported shapes.
- There is no production dependency lockfile or package manager: behavior is
  tied to the host's Bash, Python, jq, optional mail/render tools, and Claude
  CLI. CI covers Ubuntu and macOS, while deployment specifically targets Bash
  3.2 and BSD utilities.
- The application has no real integration test against Claude, live feeds,
  SMTP, launchd, or webhook services. [`tests/run.sh`](../tests/run.sh) stubs
  those boundaries and tests orchestration/failure paths instead.
- Generated state is both the database and the audit trail, but JSONL is
  agent-written and hand-editable. The sweep/portal/state readers intentionally
  skip malformed lines -- protecting availability at the cost of silently
  reduced calibration or history -- but the tolerance is not universal:
  [`bin/usage.sh`](../bin/usage.sh) feeds `state/runs.log` to `jq -rs`, so a
  single malformed row aborts the whole usage rollup (tracked in #61).
- Feed health warns after repeated failures, but a dead feed does not fail a
  run. Coverage can therefore degrade until a human refreshes/removes the feed.
- `tracking.quiet` and `tracking.horizon` surface candidates for judgment; they
  are not proof of silence or occurrence. Quiet marking uses case-insensitive
  substring matching against a shipped report, so an entity name can produce a
  false suppression in an unusual report.
- `state/.research` is scratch and is cleared on a non-resume bootstrap. A
  failed facet is represented by a stub and synthesis may proceed with partial
  coverage; deep research costs substantially more than the default linear pass.
- Profile refresh is intentionally gated by human approval, and a failed run's
  newer draft is not treated as pending. Conversely, the completion marker and
  draft/profile mtimes are operationally significant; moving or manually
  editing these files can change refresh behavior.
- The optional portal export and demo bundle include accumulated intelligence,
  recipient addresses, and webhook configuration verbatim. The bundle is not a
  redaction or privacy boundary.
- The roadmap contains designs for confidence resolution, standing questions,
  source nursery, evidence preservation, and subject threading that are not
  implemented. Do not infer those capabilities from the design documents:
  [`docs/roadmap.md`](roadmap.md) is the shipped/backlog authority.
- The current base test invocation is expected to become green when PR #77
  lands; this onboarding map treats the suite and CI contract as the intended
  verification surface rather than preserving transient base-commit test state.
