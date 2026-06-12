#!/usr/bin/env python3
"""cadence.py -- quiet detection's deterministic half, run by bin/monitor.sh.

The dog that didn't bark: each entity's sourced event history in
state/observations.jsonl gives it a normal rhythm, and an entity silent well past
that baseline is itself a finding ("no release in 8 weeks vs a ~3-week norm"). This
script does the arithmetic -- per-entity baselines and who is past them -- and leaves
the judgment ("is it genuinely quiet, or did this very sweep show otherwise?") to the
agent, the same division of labor as horizon.py.

Modes (following the horizon.py / fetch.py shape):

  quiet --as-of YYYY-MM-DD [--factor F] [--min-events N] OBSERVATIONS [FLAGS]
        -> JSONL of entities whose silence exceeds max(factor x median gap, the
           14-day floor), after suppressing silences already flagged in FLAGS,
           injected into the weekly triage prompt as a QUIET ENTITIES block.
  mark  --as-of YYYY-MM-DD FLAGS
        -> append a flag row per quiet row read on stdin, so the same silence never
           re-alarms. A flag matches on (entity, event_type, last_seen): when the
           entity resumes, last_seen advances and the stale flag simply never matches
           again -- the episode resets on resumption with no cleanup logic.

Baselines are computed per entity + event_type over `metric == "event"` rows only
(sourced facts -- their absence is meaningful; mention counts would measure our own
sweep effort). Same-day repeats collapse to one date: the gaps measure rhythm, not
volume. The median (not mean) inter-event gap is the baseline, so one long holiday
gap can't poison the rhythm; below --min-events distinct dates an entity has no
"norm" and is never flagged. The 14-day floor is a constant, not a knob -- an entity
with a 2-day cadence going silent over a long weekend is not a story.

Fail-safe by contract: malformed/non-object lines are skipped, a missing file emits
nothing, and unparseable timestamps skip the row rather than aborting the run.
Stdlib only; the source is pure ASCII so it diffs cleanly and runs anywhere python3
does. bin/portal.py imports `baselines` + `quiet_threshold` from this file so the
dossier's Cadence line shows the same numbers the monitor flags.
"""
import json
import sys
from datetime import date, datetime, timezone

FLOOR_DAYS = 14   # minimum silence before ANY entity is quiet, however fast its rhythm


def _parse_date(text):
    """A leading 'YYYY-MM-DD' (the head of any ISO string) -> date, else None."""
    if not isinstance(text, str):
        return None
    try:
        return date.fromisoformat(text[:10])
    except ValueError:
        return None


def _read_jsonl(path):
    """Objects from a JSONL file ('-' = stdin); missing file reads as empty, and
    malformed / non-object lines are skipped (the log is agent-written and
    hand-editable, so coerce rather than crash)."""
    try:
        f = sys.stdin if path == "-" else open(path, encoding="utf-8")
    except (FileNotFoundError, OSError):
        return
    with f:
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


def _median(values):
    vals = sorted(values)
    mid = len(vals) // 2
    if len(vals) % 2:
        return float(vals[mid])
    return (vals[mid - 1] + vals[mid]) / 2.0


def quiet_threshold(median_gap_days, factor):
    """Silence (days) at which an entity with this baseline counts as quiet."""
    return max(median_gap_days * factor, FLOOR_DAYS)


def baselines(obs_path, min_events):
    """Per entity + event_type cadence baselines from observations.jsonl: the median
    gap (days) between distinct event dates, for groups with >= min_events distinct
    dates. Sorted by (entity, event_type) for deterministic output."""
    groups = {}   # (entity, event_type) -> {date -> newest (ts, source)}
    for rec in _read_jsonl(obs_path):
        if rec.get("metric") != "event":
            continue
        entity = rec.get("entity")
        if not isinstance(entity, str) or not entity:
            continue
        etype = rec.get("event_type")
        if not isinstance(etype, str) or not etype:
            etype = "event"
        day = _parse_date(rec.get("timestamp"))
        if day is None:
            continue
        ts = rec.get("timestamp")
        dates = groups.setdefault((entity, etype), {})
        prev = dates.get(day)
        if prev is None or ts >= prev[0]:
            dates[day] = (ts, rec.get("source"))
    out = []
    for (entity, etype), dates in sorted(groups.items()):
        if len(dates) < max(min_events, 2):   # one date has no gaps, whatever the knob
            continue
        days = sorted(dates)
        gaps = [(b - a).days for a, b in zip(days, days[1:])]
        last = days[-1]
        out.append({
            "entity": entity,
            "event_type": etype,
            "n_events": len(days),
            "median_gap_days": _median(gaps),
            "last_seen": last.isoformat(),
            "last_source": dates[last][1],
        })
    return out


def _flag_key(rec):
    entity, etype = rec.get("entity"), rec.get("event_type")
    if not isinstance(entity, str) or not isinstance(etype, str):
        return None
    return entity + "|" + etype


def load_flags(path):
    """Latest flag row per (entity, event_type) from the quiet-state file. Append
    order is enough here -- later rows simply overwrite -- so no timestamp compare."""
    flags = {}
    for rec in _read_jsonl(path):
        key = _flag_key(rec)
        if key:
            flags[key] = rec
    return flags


def cmd_quiet(obs_path, flags_path, as_of, factor, min_events):
    """The quiet rows: baselines whose silence passed threshold, minus silences
    already flagged (same entity/event_type/last_seen). Most anomalous first."""
    flags = load_flags(flags_path)
    rows = []
    for b in baselines(obs_path, min_events):
        silence = (as_of - date.fromisoformat(b["last_seen"])).days
        if silence < quiet_threshold(b["median_gap_days"], factor):
            continue
        flag = flags.get(b["entity"] + "|" + b["event_type"])
        if flag is not None and flag.get("last_seen") == b["last_seen"]:
            continue   # this very silence was already reported
        row = dict(b)
        med = row["median_gap_days"]
        row["median_gap_days"] = int(med) if float(med).is_integer() else round(med, 1)
        row["silence_days"] = silence
        row["factor"] = round(silence / med, 1) if med else None
        rows.append(row)
    rows.sort(key=lambda r: (-(r["factor"] or 0), r["entity"], r["event_type"]))
    return rows


def cmd_mark(flags_path, as_of):
    """Append a flag row per quiet row on stdin. Tolerates junk on stdin (it is fed
    from a shell variable); a row without entity/event_type/last_seen is skipped."""
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    out = []
    for rec in _read_jsonl("-"):
        if _flag_key(rec) is None or not isinstance(rec.get("last_seen"), str):
            continue
        out.append({"timestamp": now, "entity": rec["entity"],
                    "event_type": rec["event_type"], "last_seen": rec["last_seen"],
                    "flagged": as_of.isoformat()})
    if out:
        with open(flags_path, "a", encoding="utf-8") as f:
            for rec in out:
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    return 0


def _parse_args(argv):
    if not argv or argv[0] not in ("quiet", "mark"):
        return None
    mode, as_of, factor, min_events, positional = argv[0], "", 3.0, 4, []
    i = 1
    while i < len(argv):
        arg = argv[i]
        if arg == "--as-of":
            i += 1
            as_of = argv[i] if i < len(argv) else ""
        elif arg == "--factor":
            i += 1
            try:
                factor = float(argv[i])
            except (IndexError, ValueError):
                factor = 3.0
            if not factor > 0:
                factor = 3.0
        elif arg == "--min-events":
            i += 1
            try:
                min_events = max(1, int(argv[i]))
            except (IndexError, ValueError):
                min_events = 4
        else:
            positional.append(arg)
        i += 1
    return mode, as_of, factor, min_events, positional


def main():
    parsed = _parse_args(sys.argv[1:])
    if parsed is None:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    mode, as_of_s, factor, min_events, positional = parsed
    # A missing/garbage --as-of falls back to today rather than aborting; callers
    # always pass it, but fail-safe beats a crash that would drop the whole feature.
    as_of = _parse_date(as_of_s) or date.today()
    if mode == "quiet":
        obs = positional[0] if positional else "-"
        flags = positional[1] if len(positional) > 1 else ""
        for rec in cmd_quiet(obs, flags, as_of, factor, min_events):
            print(json.dumps(rec, ensure_ascii=False))
        return 0
    if not positional:
        print("mark: missing FLAGS path", file=sys.stderr)
        return 2
    return cmd_mark(positional[0], as_of)


if __name__ == "__main__":
    sys.exit(main())
