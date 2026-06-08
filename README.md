# Vantage Point — an autonomous market-intelligence agent

Two agents over one config. **bootstrap** does the expensive research once and
writes a profile you review; **monitor** runs cheaply every day/week against that
approved profile. Both are just `claude -p` invocations wrapped in shell.

> **New here?** Read **[docs/overview.md](docs/overview.md)** — a plain-language
> explainer of what Vantage Point is, what it does, and how it can be used. This README
> is the operator's runbook.

## Layout

Committed to git (the reusable engine):
```
vantage-point/
├── README.md
├── .gitignore
├── monitor-config.example.yaml   # template: subject, anchor, seeds, scope, calibration
├── samples/                      # ready-to-copy configs for common use cases (see samples/README.md)
├── bootstrap-prompt.md           # the profile-builder prompt
├── monitor-prompt.md             # the recurring-agent (triage) prompt
├── deepdive-prompt.md            # the optional second-pass investigator prompt
├── editor-prompt.md              # the optional final-pass editor prompt
├── bin/
│   ├── bootstrap.sh
│   ├── monitor.sh                # monitor.sh {daily|weekly}
│   ├── config-lib.sh            # shared cfg_get/cfg_get_text (sourced by both agents)
│   ├── email-lib.sh             # shared email rendering + sender (sourced by both agents)
│   ├── install-launchd.sh        # install/remove the launchd agents (no repo edits)
│   ├── usage.sh                  # roll up state/runs.log: cost/turns/tokens
│   ├── dashboard.sh              # regenerate kb/index.html (entities + sparklines)
│   ├── review.sh                 # launch the grading UI (thumbs up/down)
│   ├── feedback-server.py        # the grading web app behind review.sh
│   └── dedupe-feedback.py        # collapse feedback.jsonl to latest-per-id (for bootstrap)
└── launchd/
    ├── ai.zoller.vantagepoint.daily.plist    # templates; __VP_ROOT__ filled in at install
    └── ai.zoller.vantagepoint.weekly.plist
```

Created at runtime, gitignored (a specific deployment's data):
```
├── monitor-config.yaml           # your live config (cp from the .example, then fill in)
├── profile.draft.yaml            # bootstrap writes this (review target)
├── profile.yaml                  # you promote the reviewed draft to this (ground truth)
├── state/seen.jsonl              # dedup memory: "is this NEW?"
├── state/observations.jsonl      # longitudinal metric/event memory: "is this CHANGING?"
├── state/feedback.jsonl          # your thumbs up/down grades (calibration input)
└── kb/                           # accumulated reports, per-run logs, and index.html
```

The committed half is the engine; the ignored half is one deployment. `profile.yaml`
especially never gets committed — re-pointed at a real org it's a competitive-intel
artifact built from public sources. The `derived:` blocks inside the config document
the *shape* of the profile; the live approved values live in `profile.yaml`, which
makes the review gate a literal, diffable file promotion.

## Prerequisites

- **Node.js** (LTS) — Claude Code installs via npm.
- **A Claude plan** for Claude Code to authenticate against — your **Max** subscription here.
- **macOS** for the launchd schedules below (Linux/cron alternative near the end).
- **jq** (`brew install jq` / `apt install jq`) — `monitor.sh` parses each run's
  JSON envelope into `state/runs.log`. Without it the run still works but logs a
  clear error and skips usage logging.
- Optional: **msmtp** (`brew install msmtp`) for emailed reports; a markdown
  renderer — **cmark-gfm** (`brew install cmark-gfm`) or **pandoc** — to send those
  emails as rendered HTML instead of raw markdown; **gh** for repo creation.

## One-time setup

1. Drop all the files into `~/vantage-point`, create your live config, and make
   the scripts executable:
   ```
   cp monitor-config.example.yaml monitor-config.yaml
   chmod +x bin/*.sh
   ```
   Or start from a ready-made use case in [`samples/`](samples/) — e.g.
   `cp samples/ai-frontier-models.yaml monitor-config.yaml` — and edit from there
   (AI models, dev-tools competitive intel, OSS/dependency security, AI policy).
2. Install + authenticate Claude Code **once, interactively**, so headless runs
   reuse the session. Authenticating with your **Max** account means runs draw on
   your Max plan, not per-token API billing:
   ```
   npm i -g @anthropic-ai/claude-code     # if not already installed
   claude                                 # log in with your Max account, then exit
   which claude                           # note this path — the scripts must be able to find it
   ```
   The scripts export `PATH="$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"`
   so `claude` resolves under launchd's bare environment. If `which claude` prints a
   path outside those (e.g. an nvm/fnm shim), add that directory to the `export PATH=`
   line at the top of **both** `bin/*.sh` — otherwise the scheduled job dies with
   `command not found` even though it runs fine in your shell. This is the most common
   first-run failure.
3. Fill in `monitor-config.yaml` — the subject, the anchor, and a few good seed
   URLs for each. Seeds matter most when the anchor has a thin public footprint.
4. Build and approve the profile:
   ```
   ./bin/bootstrap.sh                     # writes profile.draft.yaml
   $EDITOR profile.draft.yaml             # correct competitors, sharpen signals
   cp profile.draft.yaml profile.yaml     # approve — monitor refuses to run without this
   ```
5. Smoke-test the recurring agent by hand before scheduling:
   ```
   ./bin/monitor.sh daily   &&  ls kb/
   ./bin/monitor.sh weekly
   ```

## Scheduling (launchd)

One command — no editing of repo files:

```
./bin/install-launchd.sh
```

It generates the real plists from the `launchd/*.plist` templates into
`~/Library/LaunchAgents`, baking in this checkout's path (so the schedules point at
wherever you cloned), then loads both agents. The committed templates are never
touched, so `git status` stays clean and a fresh clone needs no re-editing. Re-run it
any time to reinstall (it reloads idempotently); `./bin/install-launchd.sh uninstall`
unloads and removes both. (It also retires any pre-rename `ai.zoller.marketmonitor.*`
agents on every run, so upgrading from the old name won't double up your scheduled runs.)

To change *when* runs fire, edit the `StartCalendarInterval` in the
`launchd/*.plist` templates and re-run the installer.

Kick one off immediately to confirm wiring:
```
launchctl kickstart -k gui/$(id -u)/ai.zoller.vantagepoint.daily
```

(Older macOS without `launchctl bootstrap`/`bootout`: `cp launchd/*.plist
~/Library/LaunchAgents/` after substituting `__VP_ROOT__` yourself, then
`launchctl load -w ~/Library/LaunchAgents/<plist>`.)

Make sure the mini doesn't sleep through the schedule (Energy settings → prevent
sleep, or wrap the script in `caffeinate`). A missed `StartCalendarInterval` fires
on wake, but only once — you don't want a sleeping mini eating your daily run.

## Running multiple instances

Want one machine watching several markets (say, AI models *and* dev-tools rivals)?
Use **one clone per instance** — at runtime they're already fully isolated (each
checkout has its own `monitor-config.yaml`, `profile.yaml`, `state/` incl. its run
lock, and `kb/`; email Subjects are namespaced by `subject.name`). The only thing
that must be unique is the launchd agent label, so set **`deployment.instance`** in
each clone's config:

```yaml
deployment:
  instance: ai-models      # a short slug; lowercased, non [a-z0-9-] -> '-'
```

Then install each clone normally:

```sh
git clone <repo> ~/vp-ai-models   &&  cd ~/vp-ai-models   && ./bin/install-launchd.sh
git clone <repo> ~/vp-devtools    &&  cd ~/vp-devtools    && ./bin/install-launchd.sh
```

Each gets its own agents — `ai.zoller.vantagepoint.<instance>.{daily,weekly}` — so
they coexist and `uninstall` only removes that checkout's agents. Leave
`deployment.instance` unset for a single deployment (labels stay un-suffixed, exactly
as before — no migration needed). Renaming an instance, or converting a single
deployment to a named one, is safe: a reinstall retires this checkout's previously
installed agents (matched by the path baked into the plist) before installing the new
labels, so no stale agents linger. An instance name that has no usable `[a-z0-9-]`
characters is rejected rather than silently treated as the default.

Notes:
- Each clone needs a *distinct* `deployment.instance` (names are slugified, so
  `AI Models` and `AI_Models` collide); an install that would hijack a label already
  owned by a different checkout is rejected rather than silently repointing it.
- The locks are per-clone, so instances run independently (and can overlap). If you'd
  rather they not run at the same minute, stagger the times in each clone's
  `launchd/*.plist`.
- `~/.msmtprc` and your Claude auth are shared across clones, which is fine. To view
  two dashboards or grading UIs at once, give each a distinct port
  (`./bin/dashboard.sh --serve 8081`, `./bin/review.sh --port 8092`).

## Email delivery (optional)

Reports always land in `kb/`. To also email them, install msmtp and add a config.
For Google Workspace (e.g. `zoller.ai`), SMTP requires an **App Password**, not your
account password — generate one at myaccount.google.com → Security → App passwords
(needs 2-Step Verification on).

`~/.msmtprc`:
```
defaults
auth           on
tls            on
tls_starttls   on
logfile        ~/.msmtp.log

account        default
host           smtp.gmail.com
port           587
from           you@zoller.ai
user           you@zoller.ai
password       <16-char app password>
```
Lock it down — msmtp refuses a world-readable file that holds a password:
```
chmod 600 ~/.msmtprc
```
Verify standalone (`echo "test" | msmtp you@zoller.ai`), then set the recipient in
`monitor-config.yaml`:
```yaml
output:
  email_to: "you@example.com"   # blank or absent = no email
```
That's the only switch — `monitor.sh` reads `output.email_to` and emails each report
via msmtp when it's set. Leave it blank to skip email and just read reports from `kb/`.
If `email_to` is set but msmtp isn't installed, the run still succeeds and logs a notice;
a send failure never loses the report (it's already written to `kb/`).

The email Subject names the monitored market — `[Vantage Point: <subject.name>] <mode>
<date>` — so if you run several agents (one config each) their mail is easy to tell
apart and filter. With no `subject.name` set it falls back to the bare `[Vantage Point]`
tag.

**Rendered HTML.** Because mail clients don't render markdown, the email is sent as
HTML when a markdown renderer is installed — `pandoc` or `cmark-gfm`, auto-detected,
no config needed (`brew install cmark-gfm` is the lightest). It goes out as
`multipart/alternative`: the markdown rides along as the plain-text part, and a lightly
styled HTML version renders in clients that support it (bare URLs become clickable). No
renderer? It falls back to a plain-text send. Either way `kb/` stays pure markdown — only
the email is converted. The startup-adjacent log line notes which form was sent
(`HTML via cmark-gfm` vs `plain text`).

**Bootstrap also emails.** The same `output.email_to` switch makes `bootstrap.sh` send
a **"profile draft ready for review"** email: a human-readable summary of what it
inferred (market, key players, anchor, rubric highlights, and its lowest-confidence
guesses to check), so you can triage the draft from your inbox. With `models.editor`
set it's polished by the editor first. This is a review *aid* — approval stays the
deliberate local step (`cp profile.draft.yaml profile.yaml`); the email even spells
that out. Same fail-safe rules: a send failure never loses the on-disk draft.

(The `output.distribution` list in the config is documentation only — it sketches the
intended multi-channel shape. Only `email_to` is wired today.)

## Running on Linux (cron) instead

launchd is macOS-only. On the Ubuntu box, skip the plists and use cron (`crontab -e`):
```
30 6 * * *  $HOME/vantage-point/bin/monitor.sh daily  >> $HOME/vantage-point/state/daily.log 2>&1
0  7 * * 1  $HOME/vantage-point/bin/monitor.sh weekly >> $HOME/vantage-point/state/weekly.log 2>&1
```
cron also runs with a minimal PATH, so the same `which claude` caveat applies — make
sure that path is in the `export PATH=` line in `bin/*.sh` (the `/opt/homebrew` entry
is harmless on Linux; add your real npm-global bin if it differs).

## Why launchd and not `/schedule`

Claude Code's own desktop scheduled tasks (`/schedule`) are the lighter native
path, but they only fire while the desktop app is open. On an always-on mini,
launchd calling `claude -p` headless is more reliable: it survives reboots, needs
no app running, and slots into the same Unix toolchain as the rest of your home lab.

## Model selection

The top-level `models:` block in `monitor-config.yaml` picks which Claude model
each agent runs on:

```yaml
models:
  bootstrap: opus     # infrequent; depth matters — spend here
  monitor:   sonnet   # daily, shallow scoring — keep it cheap
```

The defaults reflect each agent's job. **bootstrap** runs rarely and does the
deep research the whole pipeline rests on, so it's worth spending Opus there.
**monitor** runs every day doing shallow diff-and-score work, so Sonnet keeps it
cheap. Each run echoes its model in the `[bootstrap]` / `[monitor:<mode>]`
startup line, so `kb/<date>.<mode>.err` records which model produced a report.

Values may be aliases (`opus`, `sonnet`) or full model IDs (e.g.
`claude-opus-4-8`). **Which forms are accepted depends on your plan and your
Claude Code version** — check `claude --help` for the `--model` flag, and
confirm a quick `claude -p "hi" --model <value>` succeeds before committing to a
value. Remove or blank a key and that agent falls back to the CLI's default
model (with a one-line notice on stderr) — nothing is hardcoded.

## Operating notes

- **Cost lever.** Because Claude Code is authenticated against Max, the spend lives
  in your subscription, not API billing — so `--max-budget-usd` won't govern it.
  The real levers are run frequency and `--max-turns` (80 for bootstrap, 40 for
  monitor here). Daily recurring runs are exactly the use case the $200 Max tier's
  extra headroom buys you.
- **Where output goes.** Reports land in `kb/YYYY-MM-DD.{daily,weekly}.md`; stderr
  for each monitor run is alongside as `.err` (bootstrap logs to `bootstrap.err` at
  the repo root). Email delivery is wired and active whenever
  `output.email_to` is set (sent via msmtp — see "Email delivery" above); the
  Slack/Telegram lines in `monitor.sh`'s deliver block are commented placeholders
  to wire up if you want another channel.
- **Run usage log.** Each run appends one JSON line to `state/runs.log` —
  timestamp, mode, turns, duration, token usage, `session_id`, and `cost_usd`.
  That `cost_usd` is an **API-equivalent estimate**, not actual Max-subscription
  billing; treat it as a relative signal for tuning run frequency and `--max-turns`.
  Run `./bin/usage.sh [days]` (default 30) for a rolled-up summary — runs, cost,
  turns, and tokens over the window.
- **Reliability.** `monitor.sh` takes one shared lock (`state/.lock`) across both
  modes — daily and weekly write the same `state/seen.jsonl`, so they must never run
  at once — and skips if a run is already going, so an overlapping schedule or a
  manual run can't corrupt shared state (keep the daily/weekly schedules from
  overlapping; the defaults are 30 min apart). The lock records its owner by PID and
  process start time; a crashed run's lock is reclaimed only once that exact process
  is gone, so a long run (claude plus the email/render step) is never reclaimed out
  from under itself and a recycled PID can't be mistaken for the original owner. The
  claude call is wall-clock bounded by `monitoring.run_timeout_seconds` (default
  1800s, `0` to disable; needs `timeout`/`gtimeout` from coreutils) so a stall can't
  hang the job, and a hard failure prints a `run FAILED` line instead of vanishing
  into the launchd log. `state/seen.jsonl` is pruned to `monitoring.state_max_lines`
  (default 5000, `0` to disable) each run so it can't grow without bound.
- **Refresh.** Re-run `bootstrap.sh` on the `governance.profile_refresh_days`
  cadence; review the new draft against the old `profile.yaml` before promoting.
  Anchors drift — new awards, hires, capabilities — and a stale profile quietly
  mis-scores everything. `monitor.sh` warns (it doesn't refuse) when the approved
  profile's `last_bootstrapped` is older than `profile_refresh_days`, so a forgotten
  refresh is visible in the run log.
- **Tuning.** First week, read every daily and grade it. Move false positives into
  `relevance.calibration.not_relevant` and misses into `relevant`, then re-bootstrap
  so the rubric learns your taste. That feedback loop is the whole reason to
  prototype on a domain where you already know good output from noise.
- **Borderline visibility.** During tuning, the two `monitoring` knobs
  `show_borderline` (default true) and `borderline_band` (default 0.2) surface
  near-misses you'd otherwise never see: items scoring in
  `[threshold - borderline_band, threshold)` get listed in a *Considered (below
  threshold)* appendix, so a daily with only near-misses still writes a report
  instead of going silent. They're recorded to state so they aren't re-surfaced.
  Calibrate from these real examples, then set `show_borderline: false` to return
  to silent empty days.

## Trend detection (what changed)

The `tracking` block turns the monitor from a *new-items filter* into something that
also reports **what moved**. Each run, the agent records observations — a metric value
(price, listing count, mentions) or a recurring event (a leak, a hire, a filing) — per
tracked entity into `state/observations.jsonl`, then compares against prior runs and
surfaces a **What changed** section when a metric crosses `min_pct_change`, an entity
hits a `repeat_streak` of events, or mentions spike past `mention_spike_factor`. A
flagged move is material even if no single article cleared `relevance.threshold` — the
pattern *is* the signal, and a daily with only trend changes still sends.

Which entities are tracked = the profile (anchor watchlist + key players) **plus** any
you pin in `tracking.watch`. Like `show_borderline`, the thresholds start sensitive
(with confidence labels) so you can calibrate, then tighten. Set `tracking.enabled:
false` to turn the whole layer off. `observations.jsonl` is pruned to
`tracking.observations_max_lines` each run, same as `seen.jsonl`.

See `docs/roadmap.md` for the larger roadmap this is part of.

## How findings are conveyed

Reports are built to be *read and acted on*, not skimmed:
- Each report opens with a **bottom line** — the single most important thing this run
  — followed by **What changed** (trends), then items grouped by signal
  (opportunity / threat / shift), each with *why it matters → recommended action →
  confidence*.
- The **weekly** digest adds a **Watchlist status** table — a one-glance snapshot of
  each tracked entity with a unicode sparkline of recent values.
- `bin/dashboard.sh` regenerates **`kb/index.html`** after every run (disable with
  `output.dashboard: false`): a browsable snapshot of tracked entities (latest metric
  + sparkline), recent events, and links to recent reports. Run `./bin/dashboard.sh`
  by hand anytime to refresh it. (Needs `jq`, like the run log.)

### Viewing the dashboard remotely

`kb/index.html` is a local file, so serve it and reach it over your existing SSH/VS
Code session:

```
./bin/dashboard.sh --serve          # regenerate + serve kb/ on http://localhost:8000
./bin/dashboard.sh --serve 8080     # ...or pick a port
```
It binds to `127.0.0.1` only — pair it with SSH port-forwarding rather than exposing
a public listener:
```
ssh -L 8000:localhost:8000 you@mini   # then open http://localhost:8000/ on your laptop
```
In **VS Code Remote**, running `--serve` in the integrated terminal triggers VS Code's
automatic port forwarding (click the toast), or use the **Live Preview** extension on
`kb/index.html`. Report links are markdown, so they open as raw text in a browser —
read a report rendered via VS Code's markdown preview, or in the emailed HTML.

## Deep dive (two-pass investigation)

The daily monitor is intentionally cheap and shallow. It's single-pass by default —
uncomment **`models.deepdive`** in your config to add a second pass on a stronger model
that runs *only* on the handful of items triage scored highest:

1. **Triage** (the `monitor` model) sweeps, scores, and reports as usual, and queues
   its top survivors — those scoring `>= monitoring.deepdive_threshold` (default 0.85),
   capped at `monitoring.deepdive_max_items` (default 5).
2. **Deep dive** (the `deepdive` model, `deepdive-prompt.md`) investigates each queued
   item: fetches the *primary* source, **corroborates across independent sources**
   (which kills rumor amplification — uncorroborated items get downgraded/flagged),
   and deepens the so-what with history from `observations.jsonl`. It edits those
   entries in the report in place, adding a corroboration status and adjusted confidence.

It's fully **opt-in and cost-bounded**: remove `models.deepdive` and the monitor is
single-pass exactly as before. Because the deep pass only fires when triage queues
high-scorers (often zero on a quiet day) and is capped per run, daily cost stays close
to today's. Both passes are logged to `state/runs.log` with a `pass` field
(`triage` / `deepdive`) so `bin/usage.sh` accounts for each.

## Editorial pass (polish before delivery)

By default the report is delivered as the analytical passes wrote it. Uncomment
**`models.editor`** to add a dedicated *editor* (`editor-prompt.md`) as the final pass
— it turns a correct-but-raw report into a tight, scannable brief: it leads with the
single most important finding, orders by importance, cuts or merges marginal items, and
tightens the prose to the house style. It runs **after** the deep dive (so it polishes
the corroborated report) and only on days a report is actually delivered.

It's strictly editorial and **non-destructive**: the editor may only reorder, cut,
merge, and rephrase — it must **add no facts, change no figures, and keep every
surviving item's `[source](url)` and `_(confidence)_`** (no web/Bash tools are even
allowed in this pass). If it fails or empties the report, the unedited report is
restored and shipped. Like the deep dive it's opt-in and logged to `state/runs.log`
(`pass: editor`). Pairs naturally with the polished HTML email template.

## Calibration (teach it your taste)

The single biggest quality lever is grading real output. Each surfaced item carries a
short stable `id`, and `bin/review.sh` serves a tiny local web UI listing recent items
with 👍 / 👎 buttons:

```
./bin/review.sh                # grading UI on http://localhost:8000
./bin/review.sh --port 8090
ssh -L 8000:localhost:8000 you@mini   # reach it from your laptop (or VS Code Remote forward)
```

A click records the grade — with the item's full context — to `state/feedback.jsonl`
(localhost-bound, no public listener, like `dashboard.sh --serve`). The next
`bin/bootstrap.sh` reads those grades as ground-truth calibration and tunes
`relevance.rubric` (and `relevance.calibration`) to match them, then you review/approve
the draft as usual. So the loop is: **monitor surfaces → you thumb → re-bootstrap →
sharper rubric** — quality compounds the longer you run it, with no config editing by hand.

## Tests

`bash tests/run.sh` runs fast, dependency-light checks for the logic that doesn't
need the `claude` CLI — launchd plist generation (including paths with shell/XML
special characters), `monitor.sh`'s argument/review-gate behavior, email
plain-text/HTML rendering, the single-run lock (skip + stale-lock reclaim, via a stub
`claude`), state pruning, the profile-staleness warning, the two-pass deep-dive
orchestration (including failure/empty-report rollback), the `usage.sh` rollup, the
dashboard, and the feedback grading server. CI (`.github/workflows/ci.yml`) runs
`shellcheck`, `bash -n`, a `py_compile` check, and this suite on every push and PR.

## Troubleshooting

- **`claude: command not found` in the scheduled run (but fine in your shell).** The
  launchd/cron PATH doesn't include where `claude` lives. `which claude`, then add that
  dir to the `export PATH=` line in both `bin/*.sh`.
- **`no approved profile.yaml`.** Bootstrap hasn't been approved. Run
  `./bin/bootstrap.sh`, review `profile.draft.yaml`, then `cp profile.draft.yaml profile.yaml`.
- **Job never fired.** Re-run `./bin/install-launchd.sh` (it regenerates the plist with
  the correct path), confirm the agent is loaded
  (`launchctl print gui/$(id -u)/ai.zoller.vantagepoint.daily`), and the mini was awake.
  launchd logs go to `state/daily.out.log` / `state/daily.err.log`.
- **Empty daily, no email.** Correct behavior when nothing clears threshold — the run
  prints `NO_MATERIAL_ITEMS` and writes no report. Check `kb/<date>.daily.err` to confirm
  it actually ran.
- **Email fails.** Check `~/.msmtp.log`, confirm `chmod 600 ~/.msmtprc`, and that you used
  an App Password rather than your account password.
