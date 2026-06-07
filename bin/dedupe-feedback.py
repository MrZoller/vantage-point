#!/usr/bin/env python3
"""dedupe-feedback.py <feedback.jsonl> -- collapse the append-only grade log to the
latest record per id and print it as JSONL.

The review server appends a row each time you grade, so a regrade leaves an older,
contradictory row. bootstrap.sh runs this before feeding grades into calibration so
each item contributes one (latest) verdict. Malformed and non-object lines are
skipped. Stdlib only; reads the path arg (or stdin).
"""
import json
import sys


def _ts(rec):
    """A sortable timestamp string; a missing or non-string value sorts earliest.

    The log can be hand-edited, so a row may carry "timestamp": null (or a number);
    coerce to "" rather than letting None >= str raise TypeError and abort the run.
    """
    t = rec.get("timestamp")
    return t if isinstance(t, str) else ""


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "-"
    try:
        f = sys.stdin if path == "-" else open(path, encoding="utf-8")
    except FileNotFoundError:
        return
    latest = {}
    with f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(obj, dict) and obj.get("id"):
                rid = obj["id"]
                prev = latest.get(rid)
                # Keep the latest BY TIMESTAMP. The log is append-only so this usually
                # equals append order, but a manual edit or merge could reorder it.
                # ISO-8601 UTC timestamps compare lexicographically; ties keep the later line.
                if prev is None or _ts(obj) >= _ts(prev):
                    latest[rid] = obj
    for obj in latest.values():
        print(json.dumps(obj, ensure_ascii=False))


if __name__ == "__main__":
    main()
