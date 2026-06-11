# Design: rubric backtest at the profile-refresh gate

*Status: design sketch — not started. Companion to the backlog entry in
[`roadmap.md`](roadmap.md).*

## Problem

A profile refresh is the most consequential change in the system: it rewrites
`relevance.rubric`, the thing every future score depends on. Today the review gate
sees **what changed** (the Phase 15 diff) but not **what effect** the change has. A
refreshed rubric can quietly regress — start dropping the kind of item the user has
consistently thumbed up — and the regression only shows up over the following weeks
of live runs, one missed signal at a time, long after the `cp` that approved it.

Meanwhile `state/feedback.jsonl` is a labeled evaluation set sitting unused at
exactly this moment: the user's up/down verdicts, each carrying the item context
(`title`, `url`, `signal`, `score`, `so_what`) that grading recorded
(`record_grade` in `bin/portal.py`). That is enough to **re-score the graded items
under the draft rubric without re-fetching anything**, and to report agreement
before approval.

## What the reviewer sees

A new section in the "draft ready for review" email (after the Phase 15 diff) and
on the portal's `/profile?draft=1` view (beside the diff card):

```
## Backtest vs your grades

Re-scored your 47 graded items (last up/down verdict per item) under the DRAFT
rubric, blind to your verdicts:

  agrees with your verdict:   41 / 47  (87%)   [approved profile: 37 / 47 (79%)]
  would now DROP a thumbs-up:  2   <- review these before approving
  would now SURFACE a thumbs-down: 4

Would now drop (score fell below threshold 0.6):
  - [a1b2c3d4] Competitor B ships multi-agent orchestration (GA)  0.82 -> 0.41
  - [e5f6a7b8] Vendor X adopts usage-based pricing                0.71 -> 0.55 (borderline)

Would now surface (score rose above threshold 0.6):
  - [c9d0e1f2] Vendor Y "future of AI" thought-leadership post    0.30 -> 0.65
  ...
```

The "would now DROP a thumbs-up" list is the payoff: a concrete regression list,
not a vibe. The baseline in brackets makes the headline meaningful — the draft
should *beat* the approved profile's agreement, since the grades are exactly what
the re-bootstrap was told to learn from.

## Design

### Architecture (one bounded claude pass + deterministic everything else)

```
state/feedback.jsonl
  | dedupe-feedback.py            (latest verdict per id — existing)
  | backtest-lib: prepare         (filter to up/down, cap, STRIP VERDICTS)
  v
blind eval set (scratch JSONL)  --+
profile.draft.yaml              --+--> claude -p backtest-prompt.md
                                       (models.monitor, no web tools)
                                         |
                                         v
                              profile.draft.backtest.jsonl   {id, draft_score}
                                         |
  graded verdicts + recorded scores -----+--> backtest-lib: render
                                         |
                                         v
                              profile.draft.backtest.md
                                (folded into email + portal draft view)
```

Split the work the way `fetch.py` / `dedupe-feedback.py` do: the **model only
scores** (the one job that needs judgment); a **stdlib Python helper computes the
numbers** (agreement, baseline, flip lists) so the percentages are arithmetic, not
the model grading its own homework.

- `bin/backtest.py` (new, stdlib only, two modes):
  - `prepare`: read deduped feedback rows on stdin, keep `verdict` in
    `{up,down}`, keep the newest `relevance.backtest_max_items` (default 60,
    `0` = backtest off), and emit the eval set **with the `verdict` and recorded
    `score` fields stripped** — the rescoring must be blind or the model will
    anchor on the answer key. Emits nothing (exit 0) when fewer than 10 usable
    grades exist; the caller treats empty output as "skip, with a note".
  - `render`: join the agent's `profile.draft.backtest.jsonl` (`{id,
    draft_score}` per line) back to the withheld verdicts + the threshold from
    the draft, and write `profile.draft.backtest.md`. Malformed/missing rows are
    counted and reported ("3 items not scored"), never fatal.
- `backtest-prompt.md` (new, repo root like the other prompts): see draft below.
- `bin/bootstrap.sh`: a new fail-safe block after the refresh-diff step (see
  sketch below). Runs only on a refresh (`profile.yaml` exists), only when the
  draft was written, only when `prepare` produced an eval set.

### Why the *monitor* model scores it

Production scoring happens on `models.monitor` — that's the model whose reading of
the rubric actually decides what gets surfaced. Backtesting on the bootstrap model
would validate a rubric the production scorer may read differently. So the pass
runs on `models.monitor` (fallback: omit `--model`, CLI default), making the
backtest a faithful replay of triage. It also keeps it cheap.

### The baseline comes free (no second scoring pass)

Each feedback row carries the `score` the item received when it was surfaced. The
"approved profile" agreement figure is computed deterministically from that
recorded score vs the threshold vs the verdict — no extra claude call. Caveat to
state in the rendered report: recorded scores may span several historical
profiles (whichever was live when each item surfaced), so the baseline is "how the
live system actually scored these", which is arguably the more honest comparator.

### Agreement definition

Verdict-level, not score-level (LLM scores are noisy; the decision boundary is
what matters):

- `up` agrees when `draft_score >= relevance.threshold` (the *draft's* threshold).
- `down` agrees when `draft_score < relevance.threshold`.
- A flip within ±0.05 of the threshold is additionally tagged `(borderline)` in
  the flip lists so the reviewer can discount scoring jitter.
- `missed` verdicts are **excluded** (and the exclusion counted in the report):
  they have no recorded item context to rescore — they test recall, not the
  rubric, and bootstrap already consumes them on the source-ranking side. A v2
  could optionally WebFetch missed URLs and check the draft would score them in;
  out of scope here.

### Config knobs (all optional, sane fallbacks, stderr note when defaulted)

| Knob | Default | Meaning |
|---|---|---|
| `relevance.backtest_max_items` | 60 | newest N graded items to replay; `0` disables the backtest |
| `budgets.backtest_max_turns` | 30 | `--max-turns` for the scoring pass |

The minimum-grades floor (10) stays a constant: below it the percentages are
noise, and a knob nobody should turn isn't worth config surface.

### bootstrap.sh sketch

After the `$DIFF_FILE` block, before the email block:

```sh
BACKTEST_JSONL="profile.draft.backtest.jsonl"
BACKTEST_MD="profile.draft.backtest.md"
rm -f "$BACKTEST_JSONL" "$BACKTEST_MD"     # stale-run hygiene, like rm -f "$DIFF_FILE"
if [ -f "$PROFILE" ] && [ -s "$DRAFT" ] && [ -s "$FEEDBACK" ] \
   && command -v python3 >/dev/null 2>&1; then
  EVAL_SET="$(python3 bin/dedupe-feedback.py "$FEEDBACK" \
              | python3 bin/backtest.py prepare --max "$BACKTEST_MAX_ITEMS")" || EVAL_SET=""
  if [ -n "$EVAL_SET" ]; then
    echo "[bootstrap] backtest: re-scoring graded items under the draft rubric" >&2
    if claude -p "$(cat backtest-prompt.md)
...draft profile + blind eval set here..." \
        ${BT_MODEL_ARGS[@]+"${BT_MODEL_ARGS[@]}"} \
        --allowedTools "Read,Write" \
        --disallowedTools "Bash,WebSearch,WebFetch" \
        --permission-mode acceptEdits \
        --max-turns "$BACKTEST_MAX_TURNS" \
        --output-format text 2>> bootstrap.err \
       && [ -s "$BACKTEST_JSONL" ]; then
      python3 bin/backtest.py render --draft "$DRAFT" --feedback "$FEEDBACK" \
        --scores "$BACKTEST_JSONL" --out "$BACKTEST_MD" \
        || { rm -f "$BACKTEST_MD"; echo "[bootstrap] WARNING: backtest render failed - skipping" >&2; }
    else
      echo "[bootstrap] WARNING: backtest scoring pass failed - skipping (draft unaffected)" >&2
    fi
  else
    echo "[bootstrap] note: too few up/down grades to backtest - skipping" >&2
  fi
fi
```

Email folding mirrors the diff: when `$BACKTEST_MD` is non-empty, append it to
`$DELIVER` after the *What changed* section (also post-editor, so the editorial
pass can never touch the numbers). The approval hint at the end of the run gains a
line pointing at `$BACKTEST_MD` when present.

### Portal

`profile_page` (`bin/portal.py`) already builds the draft view; add a
`backtest_card()` next to `draft_diff_card()`: render `profile.draft.backtest.md`
through the existing markdown renderer when the file exists, with the
would-drop list styled as the warning it is. Unlike the diff (recomputed live via
`difflib`), the backtest is a point-in-time artifact of the scoring pass — show
its file mtime ("backtested 2026-06-10") so staleness is visible if the draft was
hand-edited afterwards. The static export ignores it (no draft on export).

### Failure modes (all warn-only; the draft is never at risk)

| Failure | Behavior |
|---|---|
| first bootstrap (no `profile.yaml`) | no backtest, silently |
| `< 10` up/down grades, or `backtest_max_items: 0` | stderr note, skip |
| claude pass fails / writes nothing / writes garbage | WARNING, skip; render never runs on a bad file |
| agent skips some ids | counted in the report ("3 not scored"), never fatal |
| `python3` missing | note, skip (same stance as the feedback dedup fallback) |
| email/portal | unchanged when the md is absent — both already conditionalize on file presence |

## backtest-prompt.md (draft)

```markdown
# Backtest prompt — replay triage against a draft profile

You are the monitor's triage scorer, replayed for a calibration check. A DRAFT
profile (not yet approved) is being reviewed, and your job is to show the reviewer
how its rubric would have scored items a human already graded — so the reviewer
can see agreement and regressions BEFORE approving it.

You score items. You do not browse, research, edit the draft, or report on
anything beyond the scores.

## Inputs
- The DRAFT profile YAML (below): use its `relevance.rubric`,
  `relevance.calibration`, and the derived subject/anchor context — exactly the
  ground truth the monitor would trust if this draft were approved.
- The evaluation set (below): one JSON object per line —
  `{ id, title, url, source, signal, so_what }`. These are real items a past
  monitor run surfaced; a human graded each one, but the verdicts are withheld
  from you on purpose. Do not try to infer or optimize for them: score each item
  on the rubric's merits, as triage would.

## Procedure
For each input item, apply the draft `relevance.rubric` to the recorded context
(title, source, so_what) and produce a 0..1 relevance score, exactly as the
monitor's scoring step does. Judge from the recorded context alone — no fetching.
If an item's context is too thin to score honestly, give it `"draft_score": null`
rather than guessing.

## Output
Write ./profile.draft.backtest.jsonl — one JSON object per input item, same order:

    { "id": "a1b2c3d4", "draft_score": 0.41 }

Every input id appears exactly once. No other keys, no commentary, no report —
the comparison against the human verdicts is computed deterministically
downstream, not by you.

## Honesty constraints
- Score each item independently on the draft rubric. Don't grade on what you
  suspect the human thought, don't smooth scores toward the threshold, and don't
  let the calibration examples leak in as anything more than the rubric's worked
  examples.
- A null score for a too-thin item beats a confident guess.
```

## Tests (`tests/run.sh`; claude is stubbed)

1. **Happy path:** seed `profile.yaml`, a draft, and a feedback log with >= 10
   up/down rows; stub `claude` to write a canned `profile.draft.backtest.jsonl`
   with one engineered up->drop flip. Assert `profile.draft.backtest.md` exists,
   contains the agreement counts, the baseline figure, and the flipped item's id
   under *Would now drop*; assert the msmtp stub's captured body contains the
   backtest section after the diff section.
2. **Blindness:** capture the prompt the claude stub received; assert it contains
   the item ids but no `"verdict"` and no recorded `"score"` fields.
3. **Too few grades:** 5 grades -> no backtest files, a stderr note, exit 0.
4. **Garbage scores:** stub writes invalid JSON -> WARNING, no `$BACKTEST_MD`,
   bootstrap still exits 0 and the draft/summary/email survive.
5. **Partial coverage:** stub omits one id -> report counts it as not scored.
6. **First run:** no `profile.yaml` -> no backtest, no warnings.
7. **Stale-file hygiene:** pre-create both backtest files, run a first-bootstrap
   scenario -> both are gone afterwards.
8. **Disabled:** `relevance.backtest_max_items: 0` -> skipped with a note.
9. **`backtest.py` unit-ish coverage** via direct invocation: prepare's filtering
   (missed excluded, cap honored, newest-first), render's agreement math and the
   borderline tag.
10. `shellcheck` on the touched shell, `python3 -m py_compile bin/backtest.py`.

## Cost

Refresh-cadence only (roughly monthly), one pass, <= 60 short items scored from
recorded context with no web access, capped at 30 turns on the (cheap) monitor
model. Negligible next to the bootstrap research pass it rides along with.
`runs.log` accounting for bootstrap passes doesn't exist today; adding a
`pass: backtest` row is possible but orthogonal — out of scope.

## Out of scope / v2 ideas

- **Backtesting `missed` items** (WebFetch each missed URL, check the draft
  scores it in) — the recall half of the same idea; needs web access and more
  budget.
- **Threshold sweep** — since the eval set is scored once, agreement at *other*
  thresholds is free arithmetic; could suggest "0.55 would have agreed 91%".
  Tempting, but it edits a human-owned knob; report-only if ever built.
- **Trend over refreshes** — keep each backtest's headline in state and chart
  agreement across refreshes on the portal's Calibration card.
