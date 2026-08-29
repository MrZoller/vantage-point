# Design: source promotion ("source nursery")

*Status: proposed (backlog — not started). Companion to the backlog entry in
[`roadmap.md`](roadmap.md).*

## Problem

Coverage rots in two directions. Phase 16's feed health catches the first —
a ranked source dying — loudly and deterministically. Nothing catches the
second: a source that **should be ranked and isn't**. Today an unranked
domain's items only ever arrive via the agentic backstop (the bounded browsing
that covers feedless sources) or a lucky search hit, which means:

- Its items arrive **unreliably** — the backstop's attention is rank-ordered,
  and an unranked domain has no rank.
- The evidence that it keeps producing surfaced (even thumbed-up) items
  **evaporates**: each bootstrap re-derives `subject.derived.news_sources`
  from research, not from the system's own surfacing history. A domain that
  earned five surfaced items since the last refresh starts the next refresh
  with no credit.

Phase 8's per-source hit rates are the precision half of source
accountability (do ranked sources earn their rank?); this is the recall half
(what's earning rank without having it?). The data already exists: every
surfaced record in `state/seen.jsonl` carries `source` (domain) and `url`,
`state/feedback.jsonl` carries the verdicts, and the profile names the ranked
world (`subject.derived.news_sources` + `subject.derived.feeds`).

## What the reader sees

**Weekly digest** — a deterministic note appended after Coming up, only when a
domain is *newly* flagged (each domain announces once, not weekly):

```
*Source nursery: `theaiinsider.tech` has earned 4 surfaced items (2 thumbed up)
in 60 days without being a ranked source — feed found (https://theaiinsider.tech/feed/).
The next profile refresh will be asked to consider promoting it.*
```

**Portal — Overview** gains a **Source nursery** card under Feed health (the
two are siblings: dying sources / missing sources):

```
Source nursery — unranked domains earning surfaced items (60d)
  domain                 surfaced   👍   feed
  theaiinsider.tech             4    2   ✓ /feed/
  eulawwatch.eu                 3    0   none found
```

**Refresh review** — the next `bootstrap.sh` run injects the candidate list
into the research pass, and the draft's diff (Phase 15) then shows any
promotion as ordinary reviewable lines in `news_sources`/`feeds`. Promotion
**never bypasses the human gate**.

## Design

### Architecture (deterministic; no new claude pass)

```
state/seen.jsonl (surfaced items: source, url, date)
state/feedback.jsonl (verdicts)            profile.yaml (the ranked world)
  |                                           |
  +--------- bin/nursery.py candidates -------+
  |   (deterministic: roll up by domain, exclude ranked,
  |    threshold, attempt feed autodiscovery, remember flags)
  v
state/nursery.json (per-domain tallies + first-flagged date)
  |                |                  |
  v                v                  v
weekly note     portal card     NURSERY CANDIDATES block in the next
(new flags      (all current     bootstrap research prompt -> draft ->
 only)           candidates)     Phase 15 diff -> human approval
```

Everything is arithmetic except the final judgment — *should* this domain be
ranked, and where — which is exactly the judgment bootstrap already owns.

### Candidate detection (`bin/nursery.py candidates`, stdlib only)

- **Roll up** surfaced records from `seen.jsonl` (full records only — dropped
  items carry no endorsement) whose `date` is within `nursery_days` (default
  60: long enough to span a refresh cycle, short enough that a domain must
  stay productive), by normalized domain: lowercased URL host, `www.`
  stripped. No public-suffix logic (stdlib-only rule); `blog.vendor.com` and
  `vendor.com` count separately, which is acceptable — feeds live at the
  subdomain anyway. Join `feedback.jsonl` latest-per-id for thumbs-up counts.
- **Exclude the ranked world**: a domain is ranked when it matches the host
  of any URL in `subject.derived.feeds` or appears (case-insensitive
  substring) in any `subject.derived.news_sources` entry — entries there are
  prose-ish ("The AI Insider — fastest on enterprise launches"), so substring
  matching against the domain and its registrable stem is the honest best
  effort; the doc and card both say "unranked *as far as the profile
  states*". Also exclude the anchor's own domains when present in the
  profile (surfacing your own blog is not source discovery).
- **Threshold**: candidate when `surfaced >= nursery_min_items` (default 3)
  **or** `thumbs_up >= 1` (an explicit human endorsement outweighs volume —
  it's the strongest signal the system has).
- **Feed autodiscovery**, bounded, for each *new* candidate only: fetch the
  domain's homepage once (`urllib`, 20s timeout, 512 KiB cap), scan for
  `<link rel="alternate" type="application/rss+xml|application/atom+xml">`;
  fall back to probing `/feed`, `/rss`, `/atom.xml`, `/index.xml` (one GET
  each). Verify any hit actually parses by reusing `fetch_feed` +
  `parse_entries` from `bin/fetch.py` (importable: `fetch` is a valid module
  name and they share a directory) — the same "must serve a parseable feed"
  bar Phase 20's `--verify` holds draft feeds to. Failure = "none found",
  never an error.
- **Memory** (`state/nursery.json`, mirroring `feedhealth.json`): per-domain
  tallies, the discovered feed URL, and `first_flagged`. The weekly note
  fires only when `first_flagged` is this run (announce once); the card shows
  everything current; a domain that drops below threshold ages out of the
  window and is pruned, so a later resurgence re-announces — a new episode,
  like quiet-detection's flags.

### Who runs it

`monitor.sh`, weekly only, after the report passes (beside the Coming up
append): candidates change at week-cadence, and the autodiscovery fetches —
though bounded — don't belong on the daily path. Fail-safe `|| true`
throughout; a network-less run just reuses the remembered tallies.

### The bootstrap handoff

`bootstrap.sh` already injects grades; add the nursery the same way: when
`state/nursery.json` has current candidates, fold a `NURSERY CANDIDATES`
block into the research prompt (single-pass and deep-research modes alike —
in deep-research mode it rides the synthesis pass's manifest, where source
ranking happens):

- These unranked domains earned surfaced/thumbed-up items since the last
  refresh (counts + discovered feed URLs attached). **Evaluate each for
  promotion** into `news_sources` (ranked honestly against the incumbents,
  not appended at the bottom) and — when the verified feed exists — into
  `feeds`. Demotion of an incumbent that the per-source hit rates show
  underperforming is equally in scope.
- A candidate is evidence, not an order: a domain can earn three surfaced
  items by syndicating others' reporting; rank the *originator*.

The draft diff then shows the promotion, the feedcheck verifies the feed
again, and the human approves — every existing gate intact.

### Config knobs (all optional, defaulted, stderr note when defaulted)

| Knob | Default | Meaning |
|---|---|---|
| `monitoring.nursery_min_items` | 3 | surfaced items (in window) before an unranked domain is flagged; `0` disables the nursery |
| `monitoring.nursery_days` | 60 | the rolling window for tallies |

The thumbs-up shortcut (≥1) and the autodiscovery probe list stay constants.

### Failure modes (warn-only; the run and report are never at risk)

| Failure | Behavior |
|---|---|
| `nursery_min_items: 0` | no tallies, no card, no injection |
| no unranked domains earn items | empty card states that; no note, no injection |
| homepage fetch / probes fail | candidate listed with "none found" feed; bootstrap can still rank the source (feedless sources are first-class — the backstop covers them) |
| ranked-world matching misses a rename | a ranked source gets nominated again; the human reviewing the draft diff catches it (annoying, not wrong) |
| `seen.jsonl` pruned shorter than the window | tallies undercount; threshold is conservative in the safe direction |
| corrupt rows / `nursery.json` damaged | skipped / rebuilt from scratch next weekly (it's a cache of derivable state) |
| `python3` missing | note, skip |

## Tests (`tests/run.sh`; claude is stubbed)

1. **Roll-up math** via direct `nursery.py` invocation: seeded `seen.jsonl` +
   `feedback.jsonl` + profile → an unranked domain with 3 surfaced items is a
   candidate; 2 surfaced + 1 thumbs-up is a candidate; 2 surfaced + 0 is not;
   a domain matching a `feeds` URL host or a `news_sources` entry is
   excluded; `www.` and case are normalized; window excludes old items.
2. **Autodiscovery** against a local fixture server (the pattern fetch.py's
   tests use): a homepage with a `rel=alternate` link → that URL, verified
   parseable; no link but `/feed` serves Atom → found by probe; nothing →
   "none found", exit 0.
3. **Announce-once:** first weekly run appends the nursery note (msmtp capture
   included); second run with unchanged state appends nothing; the card shows
   the candidate both times.
4. **Bootstrap injection:** with current candidates, the captured bootstrap
   prompt contains a `NURSERY CANDIDATES` block with the domain + feed URL;
   without, it doesn't.
5. **Silence preserved:** weekly with candidates but no report → no report
   (the note rides a report, never creates one).
6. **Disabled:** `nursery_min_items: 0` → no writes, no card, no injection.
7. **Damaged `nursery.json`** → rebuilt without aborting.
8. `shellcheck` on touched shell; `python3 -m py_compile bin/nursery.py`.

## Cost

Zero claude passes on the monitor side; a handful of bounded HTTP fetches per
*new* candidate, weekly. On the bootstrap side, a few hundred prompt tokens
riding a pass that already costs orders of magnitude more. The payoff scales
with deployment age: the longer the system runs, the more its own surfacing
history beats a from-scratch source ranking.

## Out of scope / v2 ideas

- **Auto-trial feeds** — sweep a candidate's discovered feed *before*
  promotion (a probationary feed list). Rejected for v1: it moves coverage
  changes outside the human gate, the one line this project doesn't cross.
- **Demotion nursery** — the symmetric case (ranked sources earning nothing)
  is already half-covered by Phase 8's hit rates + feed staleness; folding
  those into the same bootstrap block as explicit demotion candidates is a
  natural follow-up.
- **Origin-vs-syndicator detection** — canonical-URL / `og:url` checks to
  credit the originating domain; v1 leaves that judgment to bootstrap.
- **Registrable-domain grouping** (public-suffix list) — only if subdomain
  fragmentation proves noisy in practice; it would break the stdlib-only rule
  unless vendored as data.
