# Sample configs

Ready-to-copy starting points for common use cases. Each is a complete
`monitor-config.yaml` with the **human-authored** parts filled in and the `derived:`
blocks left empty for `bootstrap` to populate (you then review + approve them). They're
leaner than the fully annotated [`../monitor-config.example.yaml`](../monitor-config.example.yaml),
which stays the reference for what every knob does.

| Sample | Use case | SUBJECT × ANCHOR |
| --- | --- | --- |
| [`ai-frontier-models.yaml`](ai-frontier-models.yaml) | Track the LLM landscape so you know when something ships that changes which model/API to build on, what it costs, or how to integrate it. | frontier models × a team building on LLMs |
| [`devtools-competitive.yaml`](devtools-competitive.yaml) | Competitive intelligence for a developer-tools company: rival launches, pricing, funding, positioning → opportunities, threats, shifts. | AI coding/dev-tools market × your company |
| [`oss-dependency-watch.yaml`](oss-dependency-watch.yaml) | Stay ahead of what forces an upgrade/patch/migration in your dependencies: releases, breaking changes, CVEs, EOL, maintainer changes. | your dependency set × your eng team |
| [`ai-policy-regulation.yaml`](ai-policy-regulation.yaml) | Track the laws, rules, standards, and enforcement that change how an AI company can build/deploy — obligations and deadlines, not general news. | AI policy landscape × your compliance lead |

## Using one

```sh
cp samples/ai-frontier-models.yaml monitor-config.yaml   # pick the closest fit
$EDITOR monitor-config.yaml                               # fill the <...> placeholders
./bin/bootstrap.sh                                        # researches + writes profile.draft.yaml
$EDITOR profile.draft.yaml                                # review the derived blocks
cp profile.draft.yaml profile.yaml                        # approve (the quality gate)
./bin/monitor.sh daily                                    # first run
```

Or let the wizard do the copying and filling: `./bin/init.sh` starts from any of these
samples (or the blank-slate example), interviews you for the `<...>` bits — subject,
anchor, seeds, scope, competitors, delivery — and writes `monitor-config.yaml` itself,
leaving `derived:` empty for `bootstrap`. See "Guided setup" in the
[README](../README.md).

Notes:
- The `<...>` placeholders (and the seed lists) are where your specifics go — the more
  accurate the seeds, the less the agent drifts. Everything under `derived:` is filled
  by `bootstrap`, so leave it empty.
- These are starting points, not finished profiles. The big quality lever is reviewing
  the draft and grading a few items (see Calibration in the [README](../README.md)).
- Re-pointing at a different market = swap `subject`/`anchor` and re-run `bootstrap`.
