#!/usr/bin/env python3
"""horizon.py -- the forward radar's deterministic half, run by bin/monitor.sh.

The monitor records forward-dated, time-bounded expectations it reads in the sweep
(earnings dates, "GA in Q3", announced launch windows) to state/horizon.jsonl as it
goes. This script does the arithmetic on that log -- "what is due today" and "what is
coming up" -- and leaves the judgment ("did it actually happen") to the agent.

Modes (following the fetch.py / dedupe-feedback.py shape):

  due      --as-of YYYY-MM-DD [FILE]          -> JSONL of the pending expectations whose
                                                 due date has arrived, each with a
                                                 computed `overdue_days` and `past_grace`
                                                 flag, injected into the triage prompt as
                                                 a DUE EXPECTATIONS block to check.
  upcoming --as-of YYYY-MM-DD --days N [FILE]  -> a Markdown "Coming up" table (plus an
                                                 overdue/unconfirmed list) of pending
                                                 expectations due within N days, appended
                                                 to the weekly report.

Latest-row-per-id semantics, exactly like dedupe-feedback.py: an update (a slipped or
re-announced date, or a met/lapsed/withdrawn transition) is a new row with the same
`id`, and readers collapse to the newest by timestamp. Only rows that collapse to
status `pending` reach the output -- a met/lapsed/withdrawn row retires the id, which
is what stops a flagged slip from re-alarming every subsequent run.

"Overdue" is `due` plus a grace period scaled by the stated precision -- constants,
not config knobs (the design is explicit that nobody should tune these): a day missed
by a weekend is news, a quarter-precision GA needs weeks of slack before crying slip.

Fail-safe by contract: malformed/non-object lines are skipped, a missing file emits
nothing, and an unparseable due date or precision degrades safely (a bad precision ->
the lenient year grace; a bad date -> skipped) rather than aborting the run. Stdlib
only; the source is pure ASCII so it diffs cleanly and runs anywhere python3 does.
"""
import json
import sys
from datetime import date, timedelta

# Overdue grace (days past `due`) by the stated precision. A day-precision keynote
# missed over a weekend is already news; a quarter-precision GA needs three weeks'
# slack before a silent slip is worth surfacing.
GRACE_DAYS = {"day": 3, "month": 7, "quarter": 21, "half": 30, "year": 30}
DEFAULT_GRACE = 30   # unknown / hand-edited precision -> the most lenient (year) grace

# Fixed weekday/month abbreviations so the "When" labels are locale-independent and
# the source stays ASCII (no strftime locale surprises in the rendered report).
_WD = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
_MO = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun",
       "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]


def _ts(rec):
    """A sortable timestamp string; a missing/non-string value sorts earliest (the
    log is append-only and hand-editable, so coerce rather than risk None >= str)."""
    t = rec.get("timestamp")
    return t if isinstance(t, str) else ""


def _parse_date(text):
    """A leading 'YYYY-MM-DD' (the head of any ISO string) -> date, else None."""
    if not isinstance(text, str):
        return None
    try:
        return date.fromisoformat(text[:10])
    except ValueError:
        return None


def _grace(precision):
    """Grace days for a precision tag; anything unrecognized -> year-precision grace."""
    return GRACE_DAYS.get(precision, DEFAULT_GRACE) if isinstance(precision, str) \
        else DEFAULT_GRACE


def _cell(text):
    """A Markdown-table-safe cell: single line, pipes escaped so they can't split it."""
    return str(text).replace("\n", " ").replace("|", "\\|").strip()


def load_latest(path):
    """Collapse the append-only log to the newest row per id (by timestamp). A missing
    file reads as empty; malformed and non-object lines are skipped."""
    try:
        f = sys.stdin if path == "-" else open(path, encoding="utf-8")
    except FileNotFoundError:
        return {}
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
                # Newest BY TIMESTAMP wins; ISO-8601 strings compare lexicographically,
                # and ties keep the later line (append order).
                if prev is None or _ts(obj) >= _ts(prev):
                    latest[rid] = obj
    return latest


def pending(latest):
    """The still-pending expectations from a collapsed map. A row with no `status`
    counts as pending (the schema default); met/lapsed/withdrawn retire the id."""
    return [r for r in latest.values() if r.get("status", "pending") == "pending"]


def when_label(due, precision):
    """A human 'When' label honoring the stated precision: a day-precise date reads
    'Thu Jun 18', a quarter '~Sep (Q3)', a month 'by Jun 30', etc."""
    mo = _MO[due.month]
    if precision == "day":
        return "%s %s %d" % (_WD[due.weekday()], mo, due.day)
    if precision == "month":
        return "by %s %d" % (mo, due.day)
    if precision == "quarter":
        return "~%s (Q%d)" % (mo, (due.month - 1) // 3 + 1)
    if precision == "half":
        return "~H%d %d" % (1 if due.month <= 6 else 2, due.year)
    if precision == "year":
        return "by %d" % due.year
    return "by %s" % due.isoformat()


def cmd_due(latest, as_of):
    """Pending expectations whose `due` has arrived as of the date, newest concern
    first, each annotated with `overdue_days` and a `past_grace` flag."""
    rows = []
    for rec in pending(latest):
        due = _parse_date(rec.get("due"))
        if due is None or due > as_of:
            continue
        overdue = (as_of - due).days
        out = dict(rec)
        out["overdue_days"] = overdue
        out["past_grace"] = overdue > _grace(rec.get("due_precision"))
        rows.append((due, out))
    rows.sort(key=lambda r: (r[0], str(r[1].get("entity", ""))))
    return [r[1] for r in rows]


def cmd_upcoming(latest, as_of, days):
    """A Markdown 'Coming up' table of pending expectations due within `days`, plus an
    'Overdue / unconfirmed' list for ones already past grace (not yet lapsed). Empty
    string when nothing qualifies, so the caller can skip the section entirely."""
    horizon = as_of + timedelta(days=days)
    table, overdue = [], []
    for rec in pending(latest):
        due = _parse_date(rec.get("due"))
        if due is None or due > horizon:
            continue
        if (as_of - due).days > _grace(rec.get("due_precision")):
            overdue.append((due, rec))
        else:
            table.append((due, rec))
    if not table and not overdue:
        return ""
    table.sort(key=lambda r: (r[0], str(r[1].get("entity", ""))))
    overdue.sort(key=lambda r: (r[0], str(r[1].get("entity", ""))))
    out = []
    if table:
        out.append("| When | Entity | Expected | Status |")
        out.append("|------|--------|----------|--------|")
        for due, rec in table:
            event = _cell(rec.get("event", ""))
            due_text = rec.get("due_text")
            if due_text:
                event = '%s ("%s")' % (event, _cell(due_text))
            status = "due" if due <= as_of else ""
            out.append("| %s | %s | %s | %s |" % (
                _cell(when_label(due, rec.get("due_precision"))),
                _cell(rec.get("entity", "")), event, status))
    if overdue:
        if table:
            out.append("")
        out.append("Overdue / unconfirmed:")
        for due, rec in overdue:
            expected = rec.get("due_text") or when_label(due, rec.get("due_precision"))
            out.append("- %s's %s was expected %s -- %d days past, unconfirmed."
                       % (_cell(rec.get("entity", "")), _cell(rec.get("event", "")),
                          _cell(expected), (as_of - due).days))
    return "\n".join(out)


def _parse_args(argv):
    if not argv or argv[0] not in ("due", "upcoming"):
        return None
    mode, as_of, days, positional = argv[0], "", 14, []
    i = 1
    while i < len(argv):
        arg = argv[i]
        if arg == "--as-of":
            i += 1
            as_of = argv[i] if i < len(argv) else ""
        elif arg == "--days":
            i += 1
            try:
                days = max(0, int(argv[i]))
            except (IndexError, ValueError):
                days = 14
        else:
            positional.append(arg)
        i += 1
    return mode, as_of, days, (positional[0] if positional else "-")


def main():
    parsed = _parse_args(sys.argv[1:])
    if parsed is None:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    mode, as_of_s, days, path = parsed
    # A missing/garbage --as-of falls back to today rather than aborting; callers
    # always pass it, but fail-safe beats a crash that would drop the whole feature.
    as_of = _parse_date(as_of_s) or date.today()
    latest = load_latest(path)
    if mode == "due":
        for rec in cmd_due(latest, as_of):
            print(json.dumps(rec, ensure_ascii=False))
    else:
        text = cmd_upcoming(latest, as_of, days)
        if text:
            sys.stdout.write(text + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
