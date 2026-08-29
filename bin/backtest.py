#!/usr/bin/env python3
"""backtest.py -- rubric backtest at the profile-refresh gate (two modes).

A refresh rewrites `relevance.rubric`, the thing every future score depends on.
The Phase 15 diff shows the reviewer WHAT changed; this shows WHAT EFFECT it has,
by replaying the user's graded items (`state/feedback.jsonl`) against the DRAFT
rubric -- blind, on the monitor model -- and reporting agreement vs the verdicts
before approval.

Split the work the way fetch.py / dedupe-feedback.py do: the model only SCORES
(the one job that needs judgment); this helper computes the numbers (agreement,
baseline, flip lists) so the percentages are arithmetic, not the model grading
its own homework.

Modes:
  prepare  read deduped feedback rows on stdin, keep verdict in {up,down}, keep
           the newest --max (default 60), and emit the eval set with the verdict
           and recorded score STRIPPED (the rescoring must be blind). Emits
           nothing (exit 0) when fewer than 10 usable grades exist -- the caller
           treats empty output as "skip, with a note".
  render   join the agent's profile.draft.backtest.jsonl ({id, draft_score} per
           line) back to the withheld verdicts + the threshold read from the
           draft, and write the agreement report markdown. Malformed/missing
           rows are counted and reported, never fatal.

Stdlib only.
"""
import json
import sys
from urllib.parse import urlparse

MIN_GRADES = 10          # below this the percentages are noise; a constant, not a knob
DEFAULT_MAX = 60
BORDERLINE = 0.05        # a flip within this of the threshold is tagged (borderline)


# --------------------------------------------------------------------------- shared

def _read_jsonl(f):
    """Yield dict rows from an open file, skipping blank/malformed/non-object lines."""
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(obj, dict):
            yield obj


def _ts(rec):
    """Sortable timestamp string; a missing/non-string value sorts earliest (mirrors
    dedupe-feedback.py so a hand-edited log can't abort the run)."""
    t = rec.get("timestamp")
    return t if isinstance(t, str) else ""


def _num(v):
    """Coerce to float, or None when it isn't a finite number (a string score, null,
    or NaN/inf from a hand-edited log all become None)."""
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    f = float(v)
    if f != f or f in (float("inf"), float("-inf")):
        return None
    return f


def _score(v):
    """A relevance score in [0, 1], or None. The prompt requires draft_score to be 0..1
    and this helper is the deterministic guardrail around the model pass, so an
    out-of-range numeric (1.2, -0.1) is invalid output -- count it as unscored rather
    than letting it skew the agreement/flip arithmetic."""
    f = _num(v)
    if f is None or f < 0.0 or f > 1.0:
        return None
    return f


def _draft_threshold(path):
    """Read relevance.threshold from the draft YAML with the same shallow, no-library
    scan the shell's cfg_get uses: find the top-level `relevance:` block, then the
    first `threshold:` key inside it. Falls back to 0.6 (the documented default) when
    absent/blank/unparseable -- the backtest should still run, just on the default."""
    try:
        with open(path, encoding="utf-8") as f:
            in_block = False
            for raw in f:
                # A new top-level key (non-space, non-comment at col 0) ends the block.
                if in_block and raw[:1] not in (" ", "\t", "#", "\n", "\r", ""):
                    in_block = False
                stripped = raw.strip()
                if stripped.startswith("relevance:"):
                    in_block = True
                    continue
                if in_block and stripped.startswith("threshold:"):
                    val = stripped.split(":", 1)[1]
                    val = val.split("#", 1)[0].strip().strip("'\"")
                    t = _num(_to_number(val))
                    if t is not None:
                        return t
    except OSError:
        pass
    return 0.6


def _to_number(s):
    """Parse a YAML scalar string to a number, or None."""
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def _source(rec):
    """The item's source for the blind eval set. Prefer the recorded `source` (the
    publication/domain triage saw); fall back to the URL's host so older grades --
    recorded before record_grade persisted `source` -- still carry the domain context
    the rubric may weigh, instead of a bare null."""
    src = rec.get("source")
    if isinstance(src, str) and src.strip():
        return src
    url = rec.get("url")
    if isinstance(url, str) and url:
        host = urlparse(url).netloc
        if host:
            return host[4:] if host.startswith("www.") else host
    return None


# --------------------------------------------------------------------------- prepare

def _parse_max(argv):
    """--max N from argv; bad/missing falls back to the default (never aborts)."""
    max_n = DEFAULT_MAX
    i = 0
    while i < len(argv):
        if argv[i] == "--max":
            i += 1
            if i < len(argv):
                try:
                    max_n = max(0, int(argv[i]))
                except ValueError:
                    pass
        i += 1
    return max_n


def cmd_prepare(argv):
    """Filter deduped feedback (stdin) to a blind eval set on stdout.

    Keeps verdict in {up,down} (missed/other excluded -- they have no item context
    to rescore and test recall, not the rubric), takes the newest `max_n`, strips
    the verdict + recorded score, and emits oldest-first. `--max 0` disables the
    backtest (emit nothing). The MIN_GRADES floor is applied to the FINAL eval set
    (after the cap), so a cap below MIN_GRADES skips too -- agreement percentages
    over a 1-9 item sample would look meaningful from a sample we mean to skip; the
    caller reads empty output as "too few grades, skip with a note"."""
    max_n = _parse_max(argv)
    if max_n == 0:
        return 0
    rows = [r for r in _read_jsonl(sys.stdin)
            if r.get("verdict") in ("up", "down") and r.get("id")]
    rows.sort(key=_ts)            # oldest-first
    rows = rows[-max_n:]          # newest N, still oldest-first
    if len(rows) < MIN_GRADES:    # floor the CAPPED set, not the raw count
        return 0
    for r in rows:
        # Blind eval item: the recorded context the agent rescores, WITHOUT the
        # verdict or the score it earned (anchoring on either defeats the test).
        out = {
            "id": r.get("id"),
            "title": r.get("title"),
            "url": r.get("url"),
            "source": _source(r),
            "signal": r.get("signal"),
            "so_what": r.get("so_what"),
        }
        print(json.dumps(out, ensure_ascii=False))
    return 0


# --------------------------------------------------------------------------- render

def _parse_render(argv):
    opts = {"draft": "", "approved": "", "feedback": "", "eval": "", "scores": "", "out": ""}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--draft", "--approved", "--feedback", "--eval", "--scores", "--out") \
                and i + 1 < len(argv):
            opts[a[2:]] = argv[i + 1]
            i += 2
        else:
            i += 1
    return opts


def _eval_ids(path):
    """The ordered, de-duplicated ids in the prepared (blind) eval set -- the exact set
    the scorer was asked about. render's universe, so capped-out grades aren't reported
    as 'not scored' (they were never in the eval set). Empty when no path/unreadable."""
    ids, seen = [], set()
    try:
        with open(path, encoding="utf-8") as f:
            for obj in _read_jsonl(f):
                rid = obj.get("id")
                if rid and rid not in seen:
                    seen.add(rid)
                    ids.append(rid)
    except OSError:
        pass
    return ids


def _latest_verdicts(feedback_path):
    """Latest up/down verdict per id from the raw feedback log, each with the score
    the item earned when surfaced. (We dedupe here rather than trust an upstream pass
    so render stands alone in tests.)"""
    latest = {}
    try:
        with open(feedback_path, encoding="utf-8") as f:
            for obj in _read_jsonl(f):
                rid = obj.get("id")
                if not rid or obj.get("verdict") not in ("up", "down"):
                    continue
                prev = latest.get(rid)
                if prev is None or _ts(obj) >= _ts(prev):
                    latest[rid] = obj
    except OSError:
        pass
    return latest


def _agrees(verdict, score, threshold):
    """Verdict-level agreement (the decision boundary, not the noisy score):
    up agrees when score >= threshold; down agrees when score < threshold."""
    if verdict == "up":
        return score >= threshold
    return score < threshold


def cmd_render(argv):
    """Join draft scores to the withheld verdicts, compute agreement vs the recorded
    (baseline) scores, and write the report markdown. Warn-only on any trouble."""
    opts = _parse_render(argv)
    if not opts["feedback"] or not opts["scores"] or not opts["out"]:
        print("backtest render: --feedback, --scores and --out are required", file=sys.stderr)
        return 2

    threshold = _draft_threshold(opts["draft"]) if opts["draft"] else 0.6
    # Baseline = how the LIVE system scored these, so judge the recorded scores against
    # the APPROVED profile's threshold, not the draft's. Using the draft threshold here
    # would distort the comparator: raising it 0.6 -> 0.8 turns correct 0.7 thumbs-ups
    # into phantom baseline disagreements. Fall back to the draft threshold only when no
    # approved profile is supplied (a first run has no baseline to compare anyway).
    baseline_threshold = _draft_threshold(opts["approved"]) if opts["approved"] else threshold
    verdicts = _latest_verdicts(opts["feedback"])

    # The agent's scores: {id: draft_score}. A null/garbage score counts as "not
    # scored" rather than aborting the render.
    draft_scores, malformed = {}, 0
    try:
        with open(opts["scores"], encoding="utf-8") as f:
            for obj in _read_jsonl(f):
                rid = obj.get("id")
                if not rid:
                    malformed += 1
                    continue
                draft_scores[rid] = _score(obj.get("draft_score"))
    except OSError as e:
        print("backtest render: cannot read scores: %s" % e, file=sys.stderr)
        return 1

    # The scoring pass wrote nothing parseable (garbage / all-malformed). Treat it like
    # a failed pass: warn and let the caller skip, rather than emit an empty report.
    if not draft_scores:
        print("backtest render: no usable scores parsed from %s - skipping"
              % opts["scores"], file=sys.stderr)
        return 1

    # Universe = the ids the scorer was actually asked about (the prepared eval set),
    # NOT every verdict in the log. With a cap below the grade count, prepare sends only
    # the newest ids; counting the capped-out remainder as "not scored" would mislead the
    # reviewer. Fall back to all up/down verdicts when no eval set is supplied (standalone).
    universe = _eval_ids(opts["eval"]) if opts["eval"] else list(verdicts)

    agree = baseline_agree = 0
    scored = baseline_scored = 0
    not_scored = []                      # graded items the agent didn't score
    would_drop = []                      # was up, draft now scores below threshold
    would_surface = []                   # was down, draft now scores at/above threshold

    for rid in universe:
        rec = verdicts.get(rid)
        if rec is None:                  # in the eval set but no current verdict -- skip
            continue
        verdict = rec["verdict"]
        ds = draft_scores.get(rid)
        if ds is None:
            not_scored.append((rid, rec))
            continue
        scored += 1
        if _agrees(verdict, ds, threshold):
            agree += 1
        # Baseline: how the LIVE system actually scored these (recorded score vs the
        # APPROVED threshold vs verdict) -- free, no second scoring pass.
        base = _score(rec.get("score"))
        if base is not None:
            baseline_scored += 1
            if _agrees(verdict, base, baseline_threshold):
                baseline_agree += 1
        # Flips that change the decision.
        title = rec.get("title") or rec.get("url") or rid
        if verdict == "up" and ds < threshold:
            would_drop.append((rid, title, base, ds))
        elif verdict == "down" and ds >= threshold:
            would_surface.append((rid, title, base, ds))

    md = _format_report(threshold, scored, agree, baseline_agree, baseline_scored,
                        len(universe), not_scored, would_drop, would_surface, malformed)
    try:
        with open(opts["out"], "w", encoding="utf-8") as f:
            f.write(md)
    except OSError as e:
        print("backtest render: cannot write %s: %s" % (opts["out"], e), file=sys.stderr)
        return 1
    return 0


def _pct(n, d):
    return ("%d%%" % round(100.0 * n / d)) if d else "n/a"


def _flip_line(item, threshold):
    rid, title, base, ds = item
    base_s = ("%.2f" % base) if base is not None else "?"
    tag = "  (borderline)" if abs(ds - threshold) <= BORDERLINE else ""
    return "  - [%s] %s  %s -> %.2f%s" % (rid, title, base_s, ds, tag)


def _format_report(threshold, scored, agree, baseline_agree, baseline_scored, total,
                   not_scored, would_drop, would_surface, malformed):
    lines = ["## Backtest vs your grades", ""]
    if scored == 0:
        lines.append("The scoring pass returned no usable scores for your %d graded "
                     "item(s) -- nothing to compare. (The draft is unaffected.)" % total)
        if malformed or not_scored:
            lines.append("")
            lines.append("(%d item(s) not scored.)" % (len(not_scored) + malformed))
        return "\n".join(lines) + "\n"

    lines.append("Re-scored your %d graded item(s) (last up/down verdict per item) "
                "under the DRAFT rubric, blind to your verdicts:" % scored)
    lines.append("")
    lines.append("```")
    lines.append("  agrees with your verdict:   %d / %d  (%s)   [approved profile: %d / %d (%s)]"
                % (agree, scored, _pct(agree, scored),
                   baseline_agree, baseline_scored,
                   _pct(baseline_agree, baseline_scored)))
    lines.append("  would now DROP a thumbs-up:  %d%s"
                % (len(would_drop), "   <- review these before approving" if would_drop else ""))
    lines.append("  would now SURFACE a thumbs-down: %d" % len(would_surface))
    lines.append("```")
    lines.append("")

    if would_drop:
        lines.append("**Would now drop** (score fell below threshold %.2f):" % threshold)
        for it in sorted(would_drop, key=lambda x: x[3]):
            lines.append(_flip_line(it, threshold))
        lines.append("")
    if would_surface:
        lines.append("**Would now surface** (score rose to/above threshold %.2f):" % threshold)
        for it in sorted(would_surface, key=lambda x: -x[3]):
            lines.append(_flip_line(it, threshold))
        lines.append("")

    notes = []
    n_unscored = len(not_scored) + malformed
    if n_unscored:
        notes.append("%d graded item(s) were not scored (too thin to rescore, or the "
                    "pass skipped them) and are excluded from the figures above." % n_unscored)
    notes.append("Baseline = how the live system actually scored these when they "
                "surfaced (recorded score vs threshold), which may span several "
                "historical profiles. A draft that learned from your grades should "
                "beat it.")
    lines.append("*" + " ".join(notes) + "*")
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------- entry

def main():
    argv = sys.argv[1:]
    if not argv:
        print("usage: backtest.py {prepare|render} [...]", file=sys.stderr)
        return 2
    mode, rest = argv[0], argv[1:]
    if mode == "prepare":
        return cmd_prepare(rest)
    if mode == "render":
        return cmd_render(rest)
    print("backtest.py: unknown mode %r" % mode, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
