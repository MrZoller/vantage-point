# Design: deep-research-grade bootstrap

*Status: ✅ shipped (Phase 20 in [`roadmap.md`](roadmap.md)). This is the design of
record; the implementation follows it. Same format as
[`design-rubric-backtest.md`](design-rubric-backtest.md) and
[`design-forward-radar.md`](design-forward-radar.md).*

*Implementation notes (where the build refined the sketch): the per-facet wall-clock
bound is the config knob `budgets.facet_timeout_seconds` (default 1200, `0` = off);
`bin/research.py validate-plan` emits TAB-separated `id<TAB>goal<TAB>compact-json` per
facet for the shell loop; and the challenge + feed-verification reports are surfaced on
the portal's draft view as cards (beside the diff + backtest) as well as in the email.*

## Problem

Profile quality is the system's ceiling: every future run scores against what
bootstrap produced, so a shallow profile compounds into months of mediocre
briefs. Today bootstrap is **one linear agent in one context window** capped at
`budgets.bootstrap_max_turns` (80). That architecture has a quality ceiling no
turn-cap increase fixes: by mid-run the context is mostly fetched page text, and
the synthesis at the end works from a half-saturated window. Raising the cap
buys breadth and *loses* synthesis quality.

Claude's Deep Research product is built differently, and that difference — not
model choice — is why it feels more powerful: a lead agent **plans** the
investigation, **fans out** to parallel researcher subagents that each get a
fresh context window, then **synthesizes** their compressed reports, with
verification layered on. Each mechanism has a faithful, dependency-light
equivalent here:

| Deep Research mechanism | This design |
|---|---|
| Lead agent plans the investigation | **plan pass** → `plan.json` |
| Parallel researchers, fresh context each | **batched parallel `claude -p` facet passes**, one OS process + context window per facet |
| Researchers report back compressed | **structured notes files** in `state/.research/notes/` |
| Lead synthesizes from reports | **synthesis pass** = today's `bootstrap-prompt.md`, fed the notes |
| Self-critique / verification | **challenge pass** (adversarial, web-backed) + deterministic **`fetch.py --verify`** on every derived feed |
| Extended thinking | `budgets.thinking_tokens` → `MAX_THINKING_TOKENS` |
| Hundreds of tool calls | `research_max_facets × facet_max_turns`, all budgeted config |

## Why script-orchestrated processes, not the Task tool

The CLI could do this in one call: define researchers in `.claude/agents/` and
let the lead spawn them via the `Task` tool. Rejected, deliberately:

- **Budget opacity.** Subagent turns aren't governed by the parent's
  `--max-turns` in any way the `budgets:` block can audit. Separate `claude -p`
  calls give every pass its own enforced cap — the repo's existing cost model.
- **Testability.** `tests/run.sh` stubs the `claude` binary. Script-level
  orchestration keeps every phase visible to the stub harness; in-process
  subagents would make the pipeline untestable end-to-end.
- **Fail-safety and resume.** One process crash loses one facet's work, not the
  whole research run; notes persist on disk, so an interrupted bootstrap resumes
  instead of restarting (these runs are long and expensive).
- **Guaranteed parallelism.** Bash batching parallelizes by construction;
  Task-tool parallelism depends on what the model chooses to do.

This is also just the repo's idiom: deterministic orchestration in shell,
judgment in prompts. (The monitor's triage → deep-dive → editor chain is the
same pattern; this applies it to bootstrap.)

## Architecture

```
                         monitor-config.yaml + calibration grades
                                        |
                       [1] PLAN pass (models.bootstrap, ~15 turns)
                           orientation searches allowed; writes
                           state/.research/plan.json  (facet list)
                                        |
                           bin/research.py validate-plan
                           (clamp to research_max_facets; bad plan ->
                            fall back to single-pass bootstrap)
                                        |
            +------------------+-------+----------+------------------+
            v                  v                  v                  v
   [2] FACET pass       FACET pass         FACET pass          FACET pass
   (models.researcher; batched research_parallel at a time; fresh context,
    per-facet timeout + facet_max_turns; each writes
    state/.research/notes/<facet-id>.md; a failure = stub note, never abort)
            +------------------+-------+----------+------------------+
                                        |
                       [3] SYNTHESIS pass (models.bootstrap,
                           bootstrap_max_turns) = today's bootstrap-prompt.md
                           fed the notes manifest; reads notes via Read;
                           writes profile.draft.yaml + summary (as today)
                                        |
                       [4] fetch.py --verify  (deterministic: every
                           subject.derived.feeds URL in the DRAFT must
                           actually serve a parseable feed; failures
                           flagged in the summary email)
                                        |
                       [5] CHALLENGE pass (models.challenge, optional)
                           attack the draft's weakest claims with fresh
                           web evidence; non-destructive edit + report
                                        |
                           diff -> email -> human review gate (unchanged)
```

**Opt-in trigger:** `models.researcher` set ⇒ phases 1–3 replace the single
call. Unset ⇒ bootstrap behaves byte-for-byte as today (zero behavior change,
the same guarantee `models.deepdive` gives the monitor). `models.challenge` and
feed verification are independent: they take any draft, so they work in
single-pass mode too.

### Phase 1 — plan pass (`research-plan-prompt.md`)

Reads the config + calibration grades; may run a few orientation searches
(tools: `WebSearch,WebFetch,Read,Write`; cap `budgets.plan_max_turns`, default
15). Writes `state/.research/plan.json`:

```json
{ "facets": [
  { "id": "sources-feeds",
    "title": "Where news in this market breaks",
    "goal": "Ranked news_sources with verified RSS/Atom feeds",
    "questions": ["Which outlets/registries/filings break news first?",
                   "Which have working feeds?"],
    "seeds": ["https://..."],
    "deliverable": "ranked source list + feed URLs, each verified" },
  { "id": "anchor-competitive-set", "title": "...", "goal": "...",
    "questions": ["..."], "seeds": ["..."], "deliverable": "..." }
] }
```

Prompt rules: 3–`research_max_facets` facets, mutually exclusive, collectively
covering the four derived blocks; **always include** a sources-and-feeds facet
and an anchor facet (the two highest-value halves of the profile); each facet
must be researchable standalone by an agent that sees *only* the config and its
facet entry. `bin/research.py validate-plan` (stdlib) parses, clamps the facet
count, normalizes ids to slugs, and emits one facet per line for the shell loop
— exit nonzero ⇒ the script logs a WARNING and falls back to today's
single-pass bootstrap (a broken planner must never cost the user a draft).

### Phase 2 — facet passes (`research-facet-prompt.md`)

One `claude -p` per facet on `models.researcher` (typically a cheaper/faster
model than synthesis — Anthropic's own multi-agent setup uses exactly this
split), tools `WebSearch,WebFetch,Read,Write`, cap `budgets.facet_max_turns`
(default 25), per-facet wall-clock timeout (the monitor's `TIMEOUT_CMD`
pattern; default 20 min, skipped if no `timeout`/`gtimeout` binary). Each
writes `state/.research/notes/<facet-id>.md`:

```markdown
# Facet: sources-feeds
## Findings            (every claim cited inline)
- ...  [source](https://...)
## Candidate feed URLs (each one FETCHED and confirmed to serve RSS/Atom)
- https://example.com/feed  (Atom, ~daily, last entry 2026-06-09)
## Confidence
- HIGH: ... / LOW: ... (what a human should double-check)
## Dead ends           (searched, found nothing — so synthesis doesn't re-search)
```

The notes file is the compression step: synthesis never sees the facet's raw
page fetches, only this digest — that's what keeps the synthesis context clean,
and it's the same researcher→lead compression Deep Research relies on.

Batching: bash 3.2 has no `wait -n`, so run `research_parallel` (default 3)
facets as background jobs, `wait` for the batch, launch the next — bounded
concurrency without GNU parallel. Per-facet stderr goes to
`state/.research/<facet-id>.err`. A failed/timed-out/empty facet gets a stub
note ("FACET FAILED — synthesis must treat this area as unresearched") and a
loud warning; the run continues. **All** facets failing ⇒ fall back to
single-pass (synthesis with full web, as today).

`--resume`: a non-empty notes file newer than `plan.json` ⇒ facet skipped. An
interrupted run re-invoked with `bootstrap.sh --resume` redoes only what's
missing; without the flag, `state/.research/` is cleared at start (stale-run
hygiene, like the monitor's scratch files).

### Phase 3 — synthesis pass

Today's `bootstrap-prompt.md` and call, with one injected addition: the notes
manifest (paths + each facet's goal + which facets failed). Instructions:
ground every derived block in the notes (read them via `Read`; cite from
them), use the web only to fill gaps the notes flag as thin or failed, and add
a **"How this draft was researched"** provenance block to the review summary
(facets run, sources consulted, failed facets, anything unresearched) — the
docs-honesty rule applied to the draft itself. Tools and cap unchanged
(`bootstrap_max_turns`); since fetched-page bulk now lives in the notes, the
full budget goes to judgment instead of gathering.

### Phase 4 — deterministic feed verification (`fetch.py --verify`)

A guessed feed URL today only surfaces weeks later via feed health (Phase 16).
At the gate it's one deterministic sweep: `--verify` mode fetches every
`subject.derived.feeds` URL **in the draft** and reports per feed: parses as
RSS/Atom?, entry count, newest entry date, or the error. Failures are flagged
in the summary email ("2 of 9 draft feeds don't serve a feed — fix before
approving") and on stderr. Stdlib, reuses `fetch.py`'s existing fetcher/parser;
runs in both pipeline and single-pass modes. Cheap, and it converts the
prompt's "verify each URL" *instruction* into a *checked fact*.

### Phase 5 — challenge pass (`research-challenge-prompt.md`, optional)

Opt-in via `models.challenge` (a strong model; can equal `models.bootstrap`).
The draft's adversary, with web access (cap `budgets.challenge_max_turns`,
default 30): pick the highest-stakes, lowest-confidence claims — key-player
list, source ranking, competitive set, anything in `confidence_notes` — and
try to **break** them with fresh searches: missing major player? stale pricing
claim? a "competitor" that pivoted away? It writes
`profile.draft.challenge.md` (claim → verdict: confirmed / corrected /
unverifiable, with citations) and may apply *corrections* to the draft.
Non-destructive like the editor pass: draft backed up first, restored on
failure/empty; the challenge report is folded into the review email after the
diff (and never edited by the editorial pass). The review gate stays human —
this arms the reviewer, it doesn't replace them.

### Extended thinking

`budgets.thinking_tokens` (default unset = CLI default), exported as
`MAX_THINKING_TOKENS` for the bootstrap-family passes. Plan, synthesis, and
challenge are the judgment-heavy passes that benefit; one knob covers all to
keep config surface small.

### Cost accounting

This pipeline is a 4–10× bootstrap (in line with Anthropic's published
multi-agent research economics), so flying blind stops being acceptable:
every pass switches to `--output-format json` and logs to `state/runs.log`
with the monitor's `log_usage` shape (`pass`: `research-plan`,
`research-facet:<id>`, `bootstrap`, `challenge`). The existing soft monthly
budget (`budgets.monthly_cost_usd`) then sees bootstrap spend automatically,
and `usage.sh` can break a research run down per facet.

### Config knobs (all optional; absent ⇒ today's behavior or the stated default)

| Knob | Default | Meaning |
|---|---|---|
| `models.researcher` | unset | **the opt-in**: model for facet passes; unset = single-pass bootstrap exactly as today |
| `models.challenge` | unset | adversarial verification pass on the draft (works in either mode) |
| `budgets.plan_max_turns` | 15 | plan pass cap |
| `budgets.facet_max_turns` | 25 | per-facet cap |
| `budgets.research_max_facets` | 6 | clamp on the plan's facet count |
| `budgets.research_parallel` | 3 | concurrent facet processes (subscription rate-limit friendly) |
| `budgets.challenge_max_turns` | 30 | challenge pass cap |
| `budgets.thinking_tokens` | unset | `MAX_THINKING_TOKENS` for plan/synthesis/challenge |

A reference "deep research" block in `monitor-config.example.yaml`:
`models.bootstrap: opus`-class for synthesis, a fast model for
`models.researcher`, `models.challenge` = the synthesis model.

### Failure modes (the draft is sacred; every fancy step degrades, never blocks)

| Failure | Behavior |
|---|---|
| `models.researcher` unset | byte-identical single-pass bootstrap |
| plan pass fails / invalid or unclampable JSON | WARNING → single-pass fallback |
| a facet fails / times out / writes nothing | stub note; synthesis told; listed in the summary's provenance block |
| every facet fails | WARNING → synthesis runs with full web (single-pass behavior) |
| interrupted run | `state/.research/` persists; `--resume` redoes only missing facets |
| `fetch.py --verify` fails | note, skip — verification is an aid, not a gate |
| challenge fails / empties the draft | draft restored from backup, WARNING, report omitted |
| 429s under parallelism | the facet fails soft (stub note); lower `research_parallel` |
| no `timeout` binary | facets run uncapped on wall-clock, capped on turns (monitor's existing stance) |

## Prompt drafts (condensed)

**`research-plan-prompt.md`** — *"You are the lead researcher planning a
market-intelligence investigation. From the config below (subject, anchor,
seeds, scope, calibration grades), decompose the research into 3–N independent
facets that together cover: market structure, key players, where news breaks
(sources AND feeds), the anchor's interests/competitive set, and signal
definitions. Always include a sources-and-feeds facet and an anchor facet. Each
facet must be researchable by an agent seeing only the config and that facet's
entry: give it a goal, concrete questions, seed URLs, and a deliverable. You
may run a few orientation searches to split the market sensibly. Write
./state/.research/plan.json in the schema below. Plan only — do not research
the facets yourself."*

**`research-facet-prompt.md`** — *"You are one researcher on a team
investigating a market; your facet is below, with the config for context. Other
facets are covered by teammates — stay in yours. Research the public web
thoroughly: expand from the seeds, prefer primary sources, and verify any feed
URL by fetching it before you list it. Write your notes file (schema below):
every claim cited inline, candidate feeds confirmed, confidence split
HIGH/LOW, and dead ends recorded so the synthesizer doesn't re-search them.
Your notes are the ONLY thing the synthesizer sees from your work — write for
that reader. An honest 'found nothing' beats padding."*

**`research-challenge-prompt.md`** — *"You are the adversarial reviewer of a
drafted intelligence profile, before a human decides whether to approve it.
Read the draft (and research notes if present). Select the ~6 highest-stakes,
lowest-confidence claims — key players, source ranking, the competitive set,
anything in confidence_notes — and try to BREAK each with fresh web evidence:
missing major player? defunct 'competitor'? stale claim? wrong ranking? Write
./profile.draft.challenge.md: claim → verdict (confirmed / corrected /
unverifiable) → evidence, citations required. Apply only corrections you have
evidence for to the draft; downgrade, don't delete, what you can't verify.
Finding nothing wrong is a valid (and reportable) outcome."*

## Tests (`tests/run.sh`; claude is stubbed)

1. **Opt-out invariance:** `models.researcher` unset ⇒ existing bootstrap tests
   pass unchanged; exactly one claude invocation.
2. **Pipeline happy path:** stub returns a canned 2-facet `plan.json`, canned
   notes, a canned draft. Assert: 1 plan + 2 facet + 1 synthesis invocations;
   facet prompts contain only their own facet; synthesis prompt names both
   notes files; provenance block lands in the summary.
3. **Batching:** 5 facets, `research_parallel: 2` ⇒ never more than 2
   concurrent stub processes (stub records start/stop timestamps).
4. **Facet failure:** stub exits 1 for one facet ⇒ stub note written, run
   completes, summary lists the failed facet.
5. **All facets fail** ⇒ single-pass fallback (synthesis prompt = today's, no
   notes manifest).
6. **Invalid plan JSON** ⇒ single-pass fallback with a WARNING.
7. **Clamp:** an 8-facet plan with `research_max_facets: 4` runs 4.
8. **Resume:** pre-existing fresh notes file ⇒ that facet not re-invoked;
   without `--resume`, scratch cleared.
9. **`fetch.py --verify`:** draft with one good (stub-served) and one bad feed
   URL ⇒ summary email flags the bad one.
10. **Challenge non-destructive:** challenge stub empties the draft ⇒ original
    restored, WARNING, no challenge section in the email.
11. **runs.log:** one row per pass with the right `pass` labels;
    `budgets.thinking_tokens` exports `MAX_THINKING_TOKENS` (stub asserts env).
12. `shellcheck` on touched shell; `python3 -m py_compile bin/research.py`.

## Cost

Refresh-cadence only (~monthly). Defaults: 1×15 plan + 6×25 facets + 1×80
synthesis + optional 30 challenge ≈ **4–10× today's bootstrap** — the known
price of the multi-agent architecture, spent where quality compounds hardest
and now visible per pass in `runs.log` / `usage.sh` / the soft monthly budget.
The monitor's daily economics are untouched on purpose: deep-research power
pays at the profile gate, not in daily triage.

## Out of scope / v2

- **Fan-out for deep-dive** — the same batched-researcher mechanism applied to
  the monitor's deep-dive queue (one researcher per queued item). Natural
  second customer for `research-facet`-style passes once this lands.
- **Research cache** — facet notes persisted across refreshes so a re-bootstrap
  re-verifies rather than re-discovers; needs staleness rules.
- **MCP-sourced facets** — specialized sources (filings, registries) via MCP
  servers; collides with the dependency-light rule, so it waits for a real need.
- **Recursive facets** — a facet spawning sub-facets; complexity not yet earned.
