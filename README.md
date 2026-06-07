# market-monitor — runnable loop

Two agents over one config. **bootstrap** does the expensive research once and
writes a profile you review; **monitor** runs cheaply every day/week against that
approved profile. Both are just `claude -p` invocations wrapped in shell.

## Layout

Committed to git (the reusable engine):
```
market-monitor/
├── README.md
├── .gitignore
├── monitor-config.example.yaml   # template: subject, anchor, seeds, scope, calibration
├── bootstrap-prompt.md           # the profile-builder prompt
├── monitor-prompt.md             # the recurring-agent prompt
├── bin/
│   ├── bootstrap.sh
│   └── monitor.sh                # monitor.sh {daily|weekly}
└── launchd/
    ├── ai.zoller.marketmonitor.daily.plist
    └── ai.zoller.marketmonitor.weekly.plist
```

Created at runtime, gitignored (a specific deployment's data):
```
├── monitor-config.yaml           # your live config (cp from the .example, then fill in)
├── profile.draft.yaml            # bootstrap writes this (review target)
├── profile.yaml                  # you promote the reviewed draft to this (ground truth)
├── state/seen.jsonl              # longitudinal memory: dedup + "is this NEW?"
└── kb/                           # accumulated reports + per-run logs
```

The committed half is the engine; the ignored half is one deployment. `profile.yaml`
especially never gets committed — re-pointed at a real org it's a competitive-intel
artifact built from public sources. The `derived:` blocks inside the config document
the *shape* of the profile; the live approved values live in `profile.yaml`, which
makes the review gate a literal, diffable file promotion.

## One-time setup

1. Drop all the files into `~/market-monitor`, create your live config, and make
   the scripts executable:
   ```
   cp monitor-config.example.yaml monitor-config.yaml
   chmod +x bin/*.sh
   ```
2. Install + authenticate Claude Code **once, interactively**, so headless runs
   reuse the session. Authenticating with your **Max** account means runs draw on
   your Max plan, not per-token API billing:
   ```
   npm i -g @anthropic-ai/claude-code     # if not already installed
   claude                                 # log in with your Max account, then exit
   ```
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

Edit both plists, replace `REPLACE_ME` with your real path, copy them in, and load:

```
cp launchd/*.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.zoller.marketmonitor.daily.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.zoller.marketmonitor.weekly.plist
# (older macOS: launchctl load -w ~/Library/LaunchAgents/<plist>)
```

Kick one off immediately to confirm wiring:
```
launchctl kickstart -k gui/$(id -u)/ai.zoller.marketmonitor.daily
```

Make sure the mini doesn't sleep through the schedule (Energy settings → prevent
sleep, or wrap the script in `caffeinate`). A missed `StartCalendarInterval` fires
on wake, but only once — you don't want a sleeping mini eating your daily run.

## Why launchd and not `/schedule`

Claude Code's own desktop scheduled tasks (`/schedule`) are the lighter native
path, but they only fire while the desktop app is open. On an always-on mini,
launchd calling `claude -p` headless is more reliable: it survives reboots, needs
no app running, and slots into the same Unix toolchain as the rest of your home lab.

## Operating notes

- **Cost lever.** Because Claude Code is authenticated against Max, the spend lives
  in your subscription, not API billing — so `--max-budget-usd` won't govern it.
  The real levers are run frequency and `--max-turns` (80 for bootstrap, 40 for
  monitor here). Daily recurring runs are exactly the use case the $200 Max tier's
  extra headroom buys you.
- **Where output goes.** Reports land in `kb/YYYY-MM-DD.{daily,weekly}.md`; stderr
  for each run is alongside as `.err`. The `delivery` block in `monitor.sh` is
  commented out — uncomment the msmtp lines (or wire Slack/Telegram) when ready.
- **Refresh.** Re-run `bootstrap.sh` on the `governance.profile_refresh_days`
  cadence; review the new draft against the old `profile.yaml` before promoting.
  Anchors drift — new awards, hires, capabilities — and a stale profile quietly
  mis-scores everything.
- **Tuning.** First week, read every daily and grade it. Move false positives into
  `relevance.calibration.not_relevant` and misses into `relevant`, then re-bootstrap
  so the rubric learns your taste. That feedback loop is the whole reason to
  prototype on a domain where you already know good output from noise.
