#!/usr/bin/env python3
"""dedupe-feedback.py <feedback.jsonl> [--since TS] [--max N] -- collapse the
append-only grade log to the latest record per id and print it as JSONL.

The review server appends a row each time you grade, so a regrade leaves an older,
contradictory row. bootstrap.sh runs this before feeding grades into calibration so
each item contributes one (latest) verdict. monitor.sh additionally scopes the output
with --since (keep only grades newer than the profile's last_bootstrapped, i.e. not
yet folded into the rubric) and --max (the newest N, oldest first) to inject as live
calibration. Malformed lines, non-object lines, and records without a non-empty string
id are skipped. Stdlib only; reads the path arg (or stdin).
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


def _parse_args(argv):
    """(path, since, max_n) from argv. Bad/missing flag values fall back to the
    no-op default (no filter) rather than aborting -- callers treat this script as
    fail-safe and an aborted run would drop ALL calibration, the worst outcome."""
    path, since, max_n = "-", "", 0
    positional = []
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--since":
            i += 1
            since = argv[i] if i < len(argv) else ""
        elif arg == "--max":
            i += 1
            try:
                max_n = max(0, int(argv[i]))
            except (IndexError, ValueError):
                max_n = 0
        else:
            positional.append(arg)
        i += 1
    if positional:
        path = positional[0]
    return path, since, max_n


def main():
    path, since, max_n = _parse_args(sys.argv[1:])
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
            if isinstance(obj, dict) and isinstance(obj.get("id"), str) and obj["id"]:
                rid = obj["id"]
                prev = latest.get(rid)
                # Keep the latest BY TIMESTAMP. The log is append-only so this usually
                # equals append order, but a manual edit or merge could reorder it.
                # ISO-8601 UTC timestamps compare lexicographically; ties keep the later line.
                if prev is None or _ts(obj) >= _ts(prev):
                    latest[rid] = obj
    rows = list(latest.values())
    if since:
        # Strictly newer than the cutoff. A YYYY-MM-DD cutoff compares lexically
        # against ISO timestamps, so grades from the cutoff DAY itself are kept
        # ("2026-06-01T..." > "2026-06-01") -- a re-bootstrap day's grades survive.
        rows = [r for r in rows if _ts(r) > since]
    if max_n:
        # The newest N, emitted oldest-first so a prompt reads chronologically.
        rows.sort(key=_ts)
        rows = rows[-max_n:]
    for obj in rows:
        print(json.dumps(obj, ensure_ascii=False))


if __name__ == "__main__":
    main()
