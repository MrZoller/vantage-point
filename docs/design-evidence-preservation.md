# Design: evidence preservation

*Status: proposed (backlog — not started). Companion to the backlog entry in
[`roadmap.md`](roadmap.md).*

## Problem

The project's two longest-lived artifacts both rest on links that rot.
Dossiers (Phase 10) compound an entity's history for months; reports in `kb/`
are the permanent record of what was claimed and why. Every claim in both is
backed the same way — "cite. no source, no surface" — by a **URL**. But
pricing pages change silently, posts get deleted, blogs migrate and break
their permalinks, and paywalls descend. Six months in, a dossier's
load-bearing citations ("announced 'by May', source: …") can point at pages
that no longer say — or no longer exist to say — what the monitor read.

That degrades three things the system explicitly promises:

1. **Verifiability.** "Cite every item" is hollow if the citation is a 404 by
   the time anyone checks it.
2. **The forward radar's accountability.** A lapsed expectation's finding
   cites the *original announcement* — often exactly the page a vendor
   quietly rewrites when a date slips. The evidence for "they said May"
   vanishes precisely when it matters.
3. **Confidence resolution** ([`design-confidence-resolution.md`](design-confidence-resolution.md))
   — resolving an old item against a dead link is `unclear` by default.

The fix is cheap and local: at surfacing time, store a **bounded extracted-text
snippet + a content hash** per cited URL, so what the page said when it was
cited stays on disk after the link dies. Optionally, also ask the Internet
Archive to snapshot it — explicitly opt-in, because that discloses the
watchlist to a third party.

## What the reader sees

**Portal — dossiers and Review items**: each surfaced item that has a capture
gains a small `archived` link to a live-portal evidence view:

```
/evidence?id=a1b2c3d4

  Captured 2026-06-11 from https://vendor.com/blog/launch  (HTTP 200)
  sha256: 9f86d081…   (4.1 KB extracted text)

  ─────────────────────────────────────────────────────────
  Acme today announced that usage-based pricing will be
  generally available to all enterprise customers by May…
  ─────────────────────────────────────────────────────────
```

**Reports** — unchanged. Evidence is the citation's understudy, not content;
it appears when the reader goes digging, which is the portal's job.

## Design

### Architecture (deterministic post-run step; no new claude pass)

```
monitor run completes, report promoted        (existing)
  |
  | surfaced records appended to state/seen.jsonl this run (date == TODAY)
  v
bin/evidence.py capture --date TODAY          (deterministic, stdlib, bounded:
  fetch each new surfaced URL once,            urllib + html.parser)
  hash raw bytes, extract text, truncate)
  |                          \
  v                           \  (only when output.archive_org: true)
state/evidence.jsonl           fire-and-forget GET
  (append-only,                https://web.archive.org/save/<url>
   latest-per-id, pruned)
```

Capture runs **after** the report is promoted and delivered — it can slow
nothing down and break nothing upstream — in `monitor.sh` beside the portal
export, with the same best-effort contract (`|| warn`).

### The evidence record (`state/evidence.jsonl`)

One JSON object per line, append-only, latest-row-per-id (re-capturing a
re-surfaced URL replaces, not duplicates):

```json
{
  "timestamp": "2026-06-11T07:09:00Z",
  "id": "a1b2c3d4",                  // the surfaced item's id (joins seen.jsonl,
                                      // feedback.jsonl, the dossier)
  "url": "https://vendor.com/blog/launch",
  "http_status": 200,
  "content_sha256": "9f86d081...",    // hash of the RAW response bytes (pre-
                                      // extraction), so any change is detectable
  "fetched_bytes": 48231,
  "snippet": "Acme today announced ...",  // extracted text, hard-capped
  "note": null                        // or the failure reason ("timeout", ...)
}
```

A failed fetch still writes its row (with `note` and no snippet): "we tried at
surfacing time and the page was already gone" is itself evidence, and the row
stops the next run from retrying forever.

### Extraction (crude on purpose, stdlib only)

A small `html.parser.HTMLParser` subclass: drop `script`/`style`/`nav`/
`header`/`footer` subtrees, concatenate text nodes, collapse whitespace, and
hard-cap at a constant **16 KiB** of text. Non-HTML content types keep no
snippet, just the hash + metadata (hashing a PDF still proves later change).
This is deliberately not readability-grade extraction: the bar is "a human
can confirm the page said the thing", and 16 KiB of imperfect text clears it.
The dependency-light rule rules out anything better, and that's fine.

Fetch discipline: `urllib` with a 20s timeout, one attempt, redirects
followed, response read capped at 1 MiB (`fetched_bytes` records the
truncation), the same UA convention as `fetch.py`. At most
`tracking.evidence_max_items` URLs per run (default 10 — surfaced counts run
small by design; the cap is for the rare flood day).

### Sizing honesty (why pruning is by line count anyway)

At the 2000-line default cap with worst-case 16 KiB snippets,
`evidence.jsonl` tops out around 32 MB — by far the largest state file, but
local-disk-trivial, and in practice snippets average far below the cap. Line
pruning (the `prune_state` convention) keeps the *newest* captures, which is
the right bias: the oldest items have likely also aged out of `seen.jsonl`
and the dossier window. A size-based prune is a v2 nicety, not a correctness
need.

### Internet Archive submission (separate, off by default)

When `output.archive_org: true`, each successfully captured URL is also
submitted via a fire-and-forget `GET https://web.archive.org/save/<url>`
(no API key needed; response ignored beyond a stderr count). This is the only
feature in the system that **sends the watchlist anywhere**, so it's a
separate knob from capture itself, default `false`, and documented with
exactly that warning in `monitor-config.example.yaml` and
`docs/overview.md`'s privacy caveats. The endpoint is overridable via
`VP_ARCHIVE_URL` (env) so tests never touch the real service.

### Portal

- `entity_inner()` item rows and `review_inner()` items gain the `archived`
  link when the id has an evidence row (one latest-per-id read, the
  `_latest_feedback()` pattern).
- A new `/evidence?id=` view (live portal only — the static export has no
  `/entity` either): metadata header + the snippet rendered as escaped
  preformatted text. **Never rendered as markdown/HTML** — the snippet is
  fetched third-party content; `esc()` everything.
- The dossier's Expected list entries (forward radar) link the same way when
  the expectation's `item_id` has a capture — the slipped-date receipt.

### Config knobs (all optional, defaulted, stderr note when defaulted)

| Knob | Default | Meaning |
|---|---|---|
| `tracking.evidence` | `false` | capture snippets+hashes for newly surfaced items |
| `tracking.evidence_max_items` | 10 | per-run capture cap |
| `tracking.evidence_max_lines` | 2000 | prune bound for `state/evidence.jsonl` |
| `output.archive_org` | `false` | ALSO submit captured URLs to the Internet Archive (discloses watched URLs to a third party) |

Opt-in by default: capture re-fetches every surfaced URL from the monitor
machine (a second hit the publisher sees) and grows state. The 16 KiB / 1 MiB
/ 20s constants stay constants.

### `bin/evidence.py` (new, stdlib only)

- `capture --date YYYY-MM-DD --seen FILE --out FILE [--max N]` — select
  surfaced records (full records, not dropped-item stubs) with that `date`
  whose id has no evidence row yet; fetch, hash, extract, append. Exit 0
  always; per-URL failures become rows, structural failures become stderr.
- Malformed seen-rows skipped; missing files emit nothing.

### monitor.sh sketch

```sh
# after delivery, beside the portal export (best-effort):
if [ -n "$EVIDENCE_ENABLED" ] && command -v python3 >/dev/null 2>&1 && [ -f bin/evidence.py ]; then
  ${VP_ARCHIVE:+VP_ARCHIVE_URL="$VP_ARCHIVE"} python3 bin/evidence.py capture \
    --date "$TODAY" --seen "$STATE_FILE" --out state/evidence.jsonl \
    --max "$EVIDENCE_MAX_ITEMS" 2>> "kb/${TODAY}.${MODE}.err" \
    || echo "[monitor:$MODE] WARNING: evidence capture failed (report unaffected)" >&2
fi
```

Plus `prune_state state/evidence.jsonl "$EVIDENCE_MAX_LINES"` beside the
other prunes.

### Failure modes (warn-only; the run and report are never at risk)

| Failure | Behavior |
|---|---|
| `tracking.evidence: false` (default) | nothing anywhere |
| URL dead/timeout/paywalled at capture | row with `note` + status, no snippet; not retried |
| page is JS-rendered (empty extraction) | hash + metadata still stored; snippet empty — the hash alone proves later change |
| response over 1 MiB | truncated read, hashed as-read, `fetched_bytes` says so |
| archive.org slow/down | fire-and-forget; a stderr count, nothing else |
| `evidence.jsonl` pruned | oldest captures drop; dossier shows no `archived` link for them (same story as any pruned state) |
| `python3` missing | note, skip |
| portal `/evidence` with unknown id | a plain "no capture for this item" page |

## Tests (`tests/run.sh`; claude is stubbed)

1. **Capture happy path** against a local fixture server: seed `seen.jsonl`
   with today's surfaced item pointing at a fixture HTML page → one evidence
   row with the expected sha256, extracted text (script/style stripped),
   and status 200; a second run captures nothing (id already present).
2. **Bounds:** an oversized fixture page → snippet cut at the cap and
   `fetched_bytes` reflecting the read cap; `--max 1` with two new items →
   one captured this run, the other next run.
3. **Dead URL:** a 404 fixture → a row with `note`/status and no snippet;
   not retried on the next run.
4. **Non-HTML:** a fixture serving `application/pdf` bytes → hash + metadata,
   no snippet.
5. **Archive opt-in:** with `output.archive_org: true` and `VP_ARCHIVE_URL`
   pointed at the fixture server → the save endpoint receives the URL;
   default config → it provably does not (the fixture logs hits).
6. **Portal:** the dossier/Review item shows `archived` for a captured id;
   `/evidence?id=` renders the snippet escaped (seed a snippet containing
   `<script>` and assert it arrives entity-escaped); unknown id → the empty
   page; static export contains no evidence links.
7. **Pruning** honored; corrupt rows skipped; disabled default produces no
   writes.
8. `shellcheck` on touched shell; `python3 -m py_compile bin/evidence.py`.

## Cost

Zero claude passes. Per run: at most `evidence_max_items` bounded fetches
(seconds, after delivery — wall-clock invisible). Disk: tens of MB at the
pathological cap. The payoff compounds exactly like the dossiers it protects:
every month the deployment ages, more of its record is something this feature
kept verifiable.

## Out of scope / v2 ideas

- **Rot detection** — periodically re-fetch a sample of captured URLs and
  compare hashes; surface "N of this dossier's citations have changed/died
  since capture" on the portal. The hash field exists for this.
- **Size-based pruning** — prune `evidence.jsonl` by bytes instead of lines
  if real-world growth ever warrants it.
- **Capturing deep-dive corroboration links** — the deep-dive's extra
  sources are citations too; v1 captures only the item's primary URL (the
  queue records it; corroborating URLs live in prose, which would need
  extraction).
- **WARC/full-page archival** — out of scope permanently; this is a receipts
  drawer, not a crawler. The Internet Archive option is the pressure valve
  for anyone needing real archival.
