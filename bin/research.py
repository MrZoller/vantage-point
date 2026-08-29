#!/usr/bin/env python3
"""research.py -- helpers for the deep-research bootstrap pipeline (bin/bootstrap.sh).

The pipeline replicates Claude Deep Research's shape with script-orchestrated
`claude -p` passes: a PLAN pass writes a facet list, parallel FACET passes write
cited notes, and today's bootstrap prompt SYNTHESIZES from the notes. This helper
is the deterministic glue between the plan pass and the facet loop, kept out of the
shell because parsing JSON in awk is a bridge too far.

Mode:
  validate-plan [--max N] PLAN.json
      Parse the plan the plan pass wrote, keep at most N facets (clamp, default 6),
      normalize each id to a filesystem-safe slug (de-duplicated), and emit one facet
      per line as TAB-separated `id<TAB>goal<TAB>compact-json` for the shell loop to
      read. A facet with neither a usable id nor a title is dropped. Exit nonzero --
      so the caller falls back to today's single-pass bootstrap -- when the file is
      missing/unparseable, isn't the expected shape, or yields no usable facet (a
      broken planner must never cost the user a draft).

Stdlib only.
"""
import json
import re
import sys

DEFAULT_MAX = 6
# Facet ids become sibling .md, .err, and .json filenames. Keep the stem within
# the portable 255-byte component limit even with the longest suffix (".json").
MAX_SLUG_LENGTH = 250


def _slug(text):
    """A filesystem-safe facet id: lowercase, non [a-z0-9-] -> '-', collapsed and
    trimmed, then bounded for use as a filename stem. Empty when `text` has
    nothing usable."""
    s = re.sub(r"[^a-z0-9]+", "-", str(text).lower()).strip("-")
    return re.sub(r"-{2,}", "-", s)[:MAX_SLUG_LENGTH].rstrip("-")


def _deduplicate_slug(base, seen):
    """Return an unused bounded slug, reserving space for its numeric suffix."""
    slug, n = base, 2
    while slug in seen:
        suffix = "-%d" % n
        slug = base[: MAX_SLUG_LENGTH - len(suffix)].rstrip("-") + suffix
        n += 1
    return slug


def _parse_max(argv):
    """--max N (clamp on the facet count); bad/missing falls back to the default."""
    max_n = DEFAULT_MAX
    files = []
    i = 0
    while i < len(argv):
        if argv[i] == "--max":
            i += 1
            if i < len(argv):
                try:
                    max_n = max(1, int(argv[i]))
                except ValueError:
                    pass
        else:
            files.append(argv[i])
        i += 1
    return max_n, files


def validate_plan(argv):
    max_n, files = _parse_max(argv)
    if not files:
        print("research.py validate-plan: a plan.json path is required", file=sys.stderr)
        return 2
    try:
        with open(files[0], encoding="utf-8") as f:
            plan = json.load(f)
    except (OSError, ValueError) as exc:
        print("research.py: cannot read plan %s: %s" % (files[0], exc), file=sys.stderr)
        return 1

    facets = plan.get("facets") if isinstance(plan, dict) else None
    if not isinstance(facets, list) or not facets:
        print("research.py: plan has no usable 'facets' list", file=sys.stderr)
        return 1

    out, seen = [], set()
    for facet in facets:
        if not isinstance(facet, dict):
            continue
        # Prefer an explicit id; fall back to slugging the title so a planner that
        # omits ids still yields addressable facets.
        slug = _slug(facet.get("id") or "") or _slug(facet.get("title") or "")
        if not slug:
            continue
        # Bound first, then reserve room for any collision suffix: every unique id
        # must remain safe as each notes/diagnostic/stash filename, not just the first.
        slug = _deduplicate_slug(slug, seen)
        seen.add(slug)
        facet["id"] = slug           # normalize the id the synthesizer/notes will use
        # Collapse ALL whitespace (newlines + tabs included) in the human-facing goal:
        # the shell protocol is one facet per line, TAB-delimited, so a raw newline or
        # tab here would split a single facet into a corrupt extra line for the loop.
        goal = " ".join(str(facet.get("goal") or facet.get("title") or slug).split())
        # One line: id, goal (for the manifest), and the whole facet as compact JSON
        # (json.dumps escapes any tab/newline, so the TAB/line framing is safe).
        out.append("%s\t%s\t%s" % (slug, goal, json.dumps(facet, ensure_ascii=False)))
        if len(out) >= max_n:        # clamp AFTER de-dup so we emit exactly N good facets
            break

    if not out:
        print("research.py: plan yielded no usable facets", file=sys.stderr)
        return 1
    sys.stdout.write("\n".join(out) + "\n")
    return 0


def main():
    argv = sys.argv[1:]
    if not argv:
        print("usage: research.py validate-plan [--max N] PLAN.json", file=sys.stderr)
        return 2
    mode, rest = argv[0], argv[1:]
    if mode == "validate-plan":
        return validate_plan(rest)
    print("research.py: unknown mode %r" % mode, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
