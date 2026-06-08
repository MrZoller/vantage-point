#!/usr/bin/env python3
"""portal.py -- Vantage Point's unified web portal (replaces dashboard.sh + review.sh).

One localhost-only page that ties the operator surfaces together:

  /          Overview  - tracked entities + sparklines, recent events, recent runs
  /reports   Reports   - browse daily/weekly reports rendered with the email styling
  /review    Review    - thumbs up/down on surfaced items -> state/feedback.jsonl
  /profile   Profile   - the approved profile.yaml, read-only (draft flagged if present)
  /config    Config    - monitor-config.yaml, read-only

It also runs headless as a static-snapshot generator:

  python3 bin/portal.py --export [OUT]   # write kb/index.html (default), no server

The server binds 127.0.0.1 only -- reach it over an SSH-forwarded port or VS Code
Remote, exactly like the old dashboard/review tools. Stdlib only; the source is pure
ASCII (sparkline block glyphs are built from code points at runtime) so it diffs
cleanly and runs anywhere python3 does. Markdown reports render via the same
pandoc/cmark-gfm/cmark chain the email uses, with a light built-in fallback.
"""
import html
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG = os.path.join(ROOT, "monitor-config.yaml")
FEEDBACK = os.path.join(ROOT, "state", "feedback.jsonl")
OBS = os.path.join(ROOT, "state", "observations.jsonl")
RUNS = os.path.join(ROOT, "state", "runs.log")
KB = os.path.join(ROOT, "kb")
PROFILE = os.path.join(ROOT, "profile.yaml")
PROFILE_DRAFT = os.path.join(ROOT, "profile.draft.yaml")
MAX_ITEMS = 60
MAX_EVENTS = 12
MAX_REPORTS = 30

# Visual language shared with the HTML email (bin/email-lib.sh): same accent, surfaces,
# and type so the portal and the inbox feel like one product.
ACCENT = "#2f5bea"
CSS = """
:root{--accent:#2f5bea;--bg:#eef1f5;--card:#fff;--ink:#1f2933;--muted:#6b7280;
  --line:#e6e9ef;--soft:#f3f6ff}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);line-height:1.55;
  -webkit-font-smoothing:antialiased;
  font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
.topbar{background:var(--card);border-bottom:1px solid var(--line);
  border-top:4px solid var(--accent);position:sticky;top:0;z-index:5}
.topbar .inner{max-width:900px;margin:0 auto;padding:14px 24px;display:flex;
  align-items:center;gap:22px;flex-wrap:wrap}
.brand{font-weight:700;color:#10151f;font-size:17px;letter-spacing:.01em}
.brand .eyebrow{display:block;font-size:10px;font-weight:700;letter-spacing:.12em;
  color:var(--accent);text-transform:uppercase}
.nav{display:flex;gap:4px;flex-wrap:wrap;margin-left:auto}
.nav a{padding:6px 12px;border-radius:7px;color:var(--muted);font-size:14px;font-weight:600}
.nav a:hover{background:var(--soft);text-decoration:none}
.nav a.on{background:var(--accent);color:#fff}
.wrap{max-width:900px;margin:0 auto;padding:26px 24px 60px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;
  padding:22px 26px;margin:0 0 20px;box-shadow:0 1px 2px rgba(16,21,31,.04)}
h1{font-size:1.5em;margin:0 0 .15em;color:#10151f}
h2{font-size:13px;margin:0 0 14px;padding-bottom:8px;border-bottom:1px solid var(--line);
  text-transform:uppercase;letter-spacing:.05em;color:#4b5563}
.meta{color:var(--muted);font-size:.9em}
.stats{display:flex;gap:14px;flex-wrap:wrap;margin:0 0 20px}
.stat{background:var(--card);border:1px solid var(--line);border-radius:12px;
  padding:14px 18px;min-width:140px;flex:1}
.stat .n{font-size:1.5em;font-weight:700;color:#10151f;font-variant-numeric:tabular-nums}
.stat .l{font-size:11px;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)}
table{border-collapse:collapse;width:100%}
th,td{border-bottom:1px solid var(--line);padding:8px 10px;text-align:left;vertical-align:top}
th{color:var(--muted);font-weight:600;font-size:11px;text-transform:uppercase;letter-spacing:.04em}
.spark{font-size:1.15em;letter-spacing:1px;color:var(--accent);
  font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
.num{font-variant-numeric:tabular-nums}.muted{color:var(--muted)}
ul.events{list-style:none;padding:0;margin:0}
ul.events li{padding:7px 0;border-bottom:1px solid var(--line);font-size:14px}
ul.events li:last-child{border:0}
.reportlist{list-style:none;padding:0;margin:0}
.reportlist li{padding:9px 0;border-bottom:1px solid var(--line)}
.reportlist li:last-child{border:0}
.reportlist .tag{display:inline-block;font-size:10px;font-weight:700;text-transform:uppercase;
  letter-spacing:.05em;color:var(--accent);background:var(--soft);border-radius:5px;
  padding:1px 7px;margin-right:8px}
.item{border-bottom:1px solid var(--line);padding:14px 0}.item:last-child{border:0}
.sig{font-size:11px;text-transform:uppercase;letter-spacing:.04em;color:var(--muted)}
.grade{margin-top:8px;display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.grade a.btn{font-size:1.25em;text-decoration:none;padding:2px 10px;border:1px solid var(--line);
  border-radius:7px;line-height:1.6}
.grade a.btn.on{background:var(--accent);border-color:var(--accent)}
.verdict{font-size:.85em;color:var(--accent)}
.banner{background:var(--soft);border:1px solid #d6e0ff;border-left:4px solid var(--accent);
  border-radius:0 8px 8px 0;padding:12px 16px;margin:0 0 18px;font-size:14px}
.note{font-size:12px;color:var(--muted);margin-top:6px}
pre.yaml{background:#0f172a;color:#e2e8f0;padding:18px 20px;border-radius:10px;overflow-x:auto;
  font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:13px;line-height:1.5;margin:0}
pre.yaml .k{color:#7cc5ff}pre.yaml .c{color:#64748b;font-style:italic}
/* report body: mirrors bin/email-lib.sh .body so a report reads like its email */
.body h1{font-size:19px;margin:22px 0 8px;color:#10151f}
.body h2{font-size:14px;margin:26px 0 10px;padding-bottom:6px;border-bottom:1px solid #eceef2;
  text-transform:uppercase;letter-spacing:.05em;color:#4b5563}
.body h3{font-size:15px;margin:18px 0 4px;color:#10151f}
.body p{margin:9px 0}.body ul,.body ol{padding-left:20px;margin:9px 0}.body li{margin:7px 0}
.body blockquote{margin:16px 0;padding:14px 18px;background:var(--soft);
  border-left:4px solid var(--accent);border-radius:0 6px 6px 0;color:#28324a}
.body blockquote p{margin:0}
.body code{background:#f1f3f7;padding:1px 5px;border-radius:4px;font-size:.92em}
.body pre{background:#0f172a;color:#e2e8f0;padding:14px;border-radius:8px;overflow-x:auto}
.body pre code{background:none;padding:0;color:inherit}
.body table{border-collapse:collapse;width:100%;margin:12px 0;font-size:14px}
.body th{background:#f7f8fa;border-bottom:2px solid var(--line)}
.body td{border-bottom:1px solid #eef1f5}
.body td.spark{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;color:var(--accent)}
"""

NAV = [("/", "Overview"), ("/reports", "Reports"), ("/review", "Review"),
       ("/profile", "Profile"), ("/config", "Config")]


# ----------------------------------------------------------------------------- helpers

def cfg_get(block, key, path=CONFIG):
    """Read one scalar `key:` under a top-level YAML `block:` -- the same minimal scan
    bin/config-lib.sh's cfg_get does (no YAML library, per the repo convention)."""
    value = ""
    try:
        with open(path, encoding="utf-8") as f:
            in_block = False
            for line in f:
                line = line.rstrip("\n")
                if not in_block:
                    if re.match(r"^%s:[ \t]*(#.*)?$" % re.escape(block), line):
                        in_block = True
                    continue
                if line and line[0] not in " \t#":
                    break
                parts = line.split()
                if parts and parts[0] == key + ":":
                    value = line.split(key + ":", 1)[1]
                    value = re.sub(r"\s+#.*$", "", value)
                    value = value.strip().strip('"').strip("'")
                    break
    except FileNotFoundError:
        pass
    return value


def resolve_state_file():
    """monitoring.state_file (default state/seen.jsonl), normalized like monitor.sh."""
    value = cfg_get("monitoring", "state_file") or "state/seen.jsonl"
    if value.startswith("./"):
        value = value[2:]
    if os.path.isabs(value):
        return value
    return os.path.join(ROOT, value)


SEEN = resolve_state_file()


def read_jsonl(path):
    """Parse a JSONL file into a list of dicts, skipping blank/malformed/non-object
    lines (these logs are append-only and agent-written, so a bad line is expected)."""
    out = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(obj, dict):
                    out.append(obj)
    except FileNotFoundError:
        pass
    return out


def esc(value):
    return html.escape(str(value))


def safe_url(u):
    """Only http/https are safe as a rendered href; reject javascript:/data:/etc.

    `url` comes from agent-written state (LLM-derived from web sweeps), so an unsafe
    scheme would otherwise become a clickable link. Returns the url, or "" to drop it.
    """
    u = str(u).strip()
    return u if u.lower().startswith(("http://", "https://")) else ""


def spark(values):
    """Unicode sparkline (U+2581..U+2588) for a numeric series, built from code points
    at runtime so this file stays ASCII. Non-numeric values are ignored."""
    nums = [v for v in values if isinstance(v, (int, float)) and not isinstance(v, bool)]
    if not nums:
        return ""
    lo, hi = min(nums), max(nums)
    rng = hi - lo
    out = []
    for v in nums[-30:]:
        level = 0 if rng == 0 else int((v - lo) / rng * 7 + 0.5)
        out.append(chr(0x2581 + level))
    return "".join(out)


# ----------------------------------------------------------------------------- data

def tracked_entities():
    """Per (entity, metric) numeric series from observations.jsonl, sorted by entity."""
    groups = {}
    for rec in read_jsonl(OBS):
        metric = rec.get("metric")
        value = rec.get("value")
        if metric == "event" or not isinstance(value, (int, float)) or isinstance(value, bool):
            continue
        entity = rec.get("entity")
        if not entity or not metric:
            continue
        groups.setdefault((entity, metric), []).append(rec)
    rows = []
    for (entity, metric), recs in groups.items():
        recs.sort(key=lambda r: str(r.get("timestamp", "")))
        last = recs[-1]
        rows.append({
            "entity": entity, "metric": metric,
            "latest": last.get("value"), "unit": last.get("unit") or "",
            "as_of": str(last.get("timestamp", ""))[:10],
            "series": [r.get("value") for r in recs],
        })
    rows.sort(key=lambda r: (str(r["entity"]), str(r["metric"])))
    return rows


def recent_events():
    events = [r for r in read_jsonl(OBS) if r.get("metric") == "event"]
    events.sort(key=lambda r: str(r.get("timestamp", "")), reverse=True)
    return events[:MAX_EVENTS]


def list_reports():
    """Daily/weekly report basenames, newest first (names are date-prefixed)."""
    try:
        names = [n for n in os.listdir(KB) if n.endswith((".daily.md", ".weekly.md"))]
    except FileNotFoundError:
        names = []
    return sorted(names, reverse=True)


def run_stats():
    """(total runs in last 30d, summed cost, last-run ISO timestamp) from runs.log."""
    runs = read_jsonl(RUNS)
    cutoff = (datetime.now(timezone.utc) - timedelta(days=30)).strftime("%Y-%m-%dT%H:%M:%SZ")
    seen_runs, cost, last = set(), 0.0, ""
    for rec in runs:
        ts = rec.get("timestamp")
        ts = ts if isinstance(ts, str) else ""
        if ts > last:
            last = ts
        if ts and ts >= cutoff:
            # one invocation can log multiple passes (triage/deepdive/editor); count once
            seen_runs.add((ts, rec.get("mode")))
            c = rec.get("cost_usd")
            if isinstance(c, (int, float)) and not isinstance(c, bool):
                cost += c
    return len(seen_runs), cost, last


def recent_items():
    """Most-recent surfaced items (have an id + title; not dropped)."""
    items, ids = [], set()
    for rec in reversed(read_jsonl(SEEN)):
        rid, title = rec.get("id"), rec.get("title")
        if not rid or not title or rec.get("signal") == "dropped" or rid in ids:
            continue
        ids.add(rid)
        items.append(rec)
        if len(items) >= MAX_ITEMS:
            break
    return items


def _ts(rec):
    t = rec.get("timestamp")
    return t if isinstance(t, str) else ""


def latest_verdicts():
    """id -> newest verdict (by timestamp) from the feedback log."""
    latest = {}
    for rec in read_jsonl(FEEDBACK):
        rid = rec.get("id")
        if not rid:
            continue
        prev = latest.get(rid)
        if prev is None or _ts(rec) >= _ts(prev):
            latest[rid] = rec
    return {rid: rec.get("verdict") for rid, rec in latest.items()}


def record_grade(item, verdict):
    rec = {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "id": item.get("id"), "verdict": verdict,
        "title": item.get("title"), "url": item.get("url"),
        "signal": item.get("signal"), "score": item.get("score"),
        "so_what": item.get("so_what"),
    }
    os.makedirs(os.path.dirname(FEEDBACK), exist_ok=True)
    with open(FEEDBACK, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")


# ----------------------------------------------------------------------------- markdown

def _light_md(md):
    """A tiny, safe markdown subset for when no pandoc/cmark is installed: headings,
    bold, links, bullet lists, blockquotes, rules. Everything is escaped first, so no
    raw HTML from the report can leak through. Tables/other blocks pass as plain text."""
    def inline(s):
        s = esc(s)
        s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
        s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)

        def link(m):
            url = safe_url(m.group(2))
            return ('<a href="%s">%s</a>' % (esc(url), m.group(1))) if url else m.group(1)
        return re.sub(r"\[([^\]]+)\]\(([^)]+)\)", link, s)

    out, in_ul, in_bq = [], False, False

    def close():
        nonlocal in_ul, in_bq
        if in_ul:
            out.append("</ul>")
            in_ul = False
        if in_bq:
            out.append("</blockquote>")
            in_bq = False

    for raw in md.split("\n"):
        line = raw.rstrip()
        if not line.strip():
            close()
            continue
        m = re.match(r"^(#{1,3})\s+(.*)$", line)
        if m:
            close()
            lvl = len(m.group(1))
            out.append("<h%d>%s</h%d>" % (lvl, inline(m.group(2)), lvl))
        elif re.match(r"^[-*]\s+", line):
            if not in_ul:
                close()
                out.append("<ul>")
                in_ul = True
            out.append("<li>%s</li>" % inline(re.sub(r"^[-*]\s+", "", line)))
        elif line.startswith(">"):
            if not in_bq:
                close()
                out.append("<blockquote>")
                in_bq = True
            out.append("<p>%s</p>" % inline(line.lstrip("> ").rstrip()))
        elif re.match(r"^(-{3,}|\*{3,})$", line.strip()):
            close()
            out.append("<hr>")
        else:
            close()
            out.append("<p>%s</p>" % inline(line))
    close()
    return "\n".join(out)


def render_markdown(md):
    """Render report markdown to an HTML fragment using the same renderer chain as the
    email (pandoc/cmark-gfm/cmark); fall back to the light renderer if none is present."""
    for cmd, args in (("pandoc", ["-f", "gfm", "-t", "html"]),
                      ("cmark-gfm", ["-e", "autolink", "-e", "table", "-e",
                                     "strikethrough", "-e", "tagfilter"]),
                      ("cmark", [])):
        if shutil.which(cmd):
            try:
                p = subprocess.run([cmd] + args, input=md, capture_output=True,
                                   text=True, timeout=20)
                if p.returncode == 0 and p.stdout.strip():
                    return p.stdout
            except (OSError, subprocess.SubprocessError):
                pass
    return _light_md(md)


# ----------------------------------------------------------------------------- views

def shell(active, inner):
    nav = "".join(
        '<a href="%s"%s>%s</a>' % (path, ' class="on"' if path == active else "", esc(label))
        for path, label in NAV)
    return ("<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\">"
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
            "<title>Vantage Point</title><style>%s</style></head><body>"
            "<div class=\"topbar\"><div class=\"inner\">"
            "<div class=\"brand\"><span class=\"eyebrow\">Vantage Point</span>"
            "market intelligence</div><nav class=\"nav\">%s</nav></div></div>"
            "<div class=\"wrap\">%s</div></body></html>" % (CSS, nav, inner)).encode("utf-8")


def overview_inner(static=False):
    parts = []
    runs, cost, last = run_stats()
    rows = tracked_entities()
    parts.append('<div class="stats">')
    parts.append('<div class="stat"><div class="n">%d</div><div class="l">tracked metrics</div></div>'
                 % len(rows))
    parts.append('<div class="stat"><div class="n">%d</div><div class="l">runs (30d)</div></div>' % runs)
    parts.append('<div class="stat"><div class="n">$%.2f</div><div class="l">cost (30d)</div></div>' % cost)
    parts.append('<div class="stat"><div class="n" style="font-size:1em">%s</div>'
                 '<div class="l">last run</div></div>'
                 % (esc(last.replace("T", " ")[:16]) if last else "&mdash;"))
    parts.append('</div>')

    parts.append('<div class="card"><h2>Tracked entities</h2>')
    if rows:
        parts.append('<table><tr><th>Entity</th><th>Metric</th><th>Latest</th>'
                     '<th>Recent</th><th>As of</th></tr>')
        for r in rows:
            parts.append('<tr><td>%s</td><td>%s</td><td class="num">%s %s</td>'
                         '<td class="spark">%s</td><td class="muted">%s</td></tr>'
                         % (esc(r["entity"]), esc(r["metric"]), esc(r["latest"]),
                            esc(r["unit"]), spark(r["series"]), esc(r["as_of"])))
        parts.append('</table>')
    else:
        parts.append('<p class="muted">No numeric observations yet &mdash; they '
                     'accumulate as the monitor runs.</p>')
    parts.append('</div>')

    events = recent_events()
    if events:
        parts.append('<div class="card"><h2>Recent events</h2><ul class="events">')
        for e in events:
            note = e.get("note")
            if not note:
                v = e.get("value")
                note = v if isinstance(v, str) else ""
            parts.append('<li class="muted">%s | %s | %s: %s</li>'
                         % (esc(str(e.get("timestamp", ""))[:10]), esc(e.get("entity", "")),
                            esc(e.get("event_type", "event")), esc(note)))
        parts.append('</ul></div>')

    parts.append('<div class="card"><h2>Recent reports</h2>')
    reports = list_reports()[:14]
    if reports:
        parts.append('<ul class="reportlist">')
        for name in reports:
            kind = "weekly" if name.endswith(".weekly.md") else "daily"
            href = esc(name) if static else "/reports?f=" + esc(name)
            parts.append('<li><span class="tag">%s</span><a href="%s">%s</a></li>'
                         % (kind, href, esc(name)))
        parts.append('</ul>')
    else:
        parts.append('<p class="muted">No reports yet.</p>')
    parts.append('</div>')
    return "".join(parts)


def reports_inner(query):
    name = (query.get("f") or [""])[0]
    available = list_reports()
    if name:
        if name not in available:   # guard against path traversal / stale links
            return '<div class="card"><h1>Report not found</h1>' \
                   '<p class="muted"><a href="/reports">Back to reports</a></p></div>'
        with open(os.path.join(KB, name), encoding="utf-8") as f:
            md = f.read()
        kind = "Weekly digest" if name.endswith(".weekly.md") else "Daily briefing"
        date = name.split(".", 1)[0]
        body = render_markdown(md)
        return ('<p class="meta"><a href="/reports">&larr; All reports</a></p>'
                '<div class="card"><div class="brand" style="margin-bottom:4px">'
                '<span class="eyebrow">Vantage Point</span>Market intelligence</div>'
                '<p class="meta">%s &middot; %s</p><hr style="border:0;border-top:1px solid '
                'var(--line);margin:14px 0"><div class="body">%s</div></div>'
                % (esc(kind), esc(date), body))
    parts = ['<h1>Reports</h1><p class="meta">The same briefings that go out by email, '
             'rendered here.</p><div class="card">']
    if available:
        parts.append('<ul class="reportlist">')
        for n in available[:MAX_REPORTS]:
            kind = "weekly" if n.endswith(".weekly.md") else "daily"
            parts.append('<li><span class="tag">%s</span><a href="/reports?f=%s">%s</a></li>'
                         % (kind, esc(n), esc(n)))
        parts.append('</ul>')
    else:
        parts.append('<p class="muted">No reports yet &mdash; they land here after a monitor run.</p>')
    parts.append('</div>')
    return "".join(parts)


def review_inner(just=None):
    items = recent_items()
    verdicts = latest_verdicts()
    parts = ['<h1>Grade surfaced items</h1>',
             '<p class="meta">Your thumbs feed <code>state/feedback.jsonl</code>; the next '
             'bootstrap calibrates the rubric from them.</p>']
    if just:
        parts.append('<div class="banner">Recorded: %s &rarr; %s</div>'
                     % (esc(just[0]), esc(just[1])))
    parts.append('<div class="card">')
    if not items:
        parts.append('<p class="muted">No surfaced items yet.</p>')
    for it in items:
        rid = esc(it.get("id"))
        v = verdicts.get(it.get("id"))
        up = " on" if v == "up" else ""
        down = " on" if v == "down" else ""
        parts.append('<div class="item"><div class="sig">%s &middot; score %s</div>'
                     % (esc(it.get("signal", "?")), esc(it.get("score", "?"))))
        parts.append('<div><strong>%s</strong></div>' % esc(it.get("title", "")))
        if it.get("so_what"):
            parts.append('<div class="muted">%s</div>' % esc(it["so_what"]))
        parts.append('<div class="grade">'
                     '<a class="btn up%s" href="/grade?id=%s&v=up" title="relevant">&#128077;</a>'
                     '<a class="btn down%s" href="/grade?id=%s&v=down" title="not relevant">&#128078;</a>'
                     % (up, rid, down, rid))
        link = safe_url(it.get("url"))
        if link:
            parts.append('<a href="%s" target="_blank" rel="noopener noreferrer">source</a>'
                         % esc(link))
        if v:
            parts.append('<span class="verdict">graded: %s</span>' % esc(v))
        parts.append('</div></div>')
    parts.append('</div>')
    return "".join(parts)


def render_yaml(text):
    """Read-only YAML rendering: escape everything, then lightly tint comments and keys.
    Display only -- the file is never written from here."""
    lines = []
    for raw in text.split("\n"):
        line = esc(raw)
        stripped = raw.lstrip()
        if stripped.startswith("#"):
            lines.append('<span class="c">%s</span>' % line)
            continue
        m = re.match(r"^(\s*-?\s*)([A-Za-z0-9_.\- ]+:)(.*)$", raw)
        if m:
            lines.append("%s<span class=\"k\">%s</span>%s"
                         % (esc(m.group(1)), esc(m.group(2)), esc(m.group(3))))
        else:
            lines.append(line)
    return '<pre class="yaml">%s</pre>' % "\n".join(lines)


def file_view_inner(title, path, intro, missing, banner=""):
    parts = ["<h1>%s</h1>" % esc(title), '<p class="meta">%s</p>' % intro]
    if banner:
        parts.append(banner)
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            parts.append('<div class="card">%s</div>' % render_yaml(f.read()))
    else:
        parts.append('<div class="card"><p class="muted">%s</p></div>' % esc(missing))
    return "".join(parts)


def profile_inner(query):
    draft = (query.get("draft") or [""])[0] == "1"
    banner = ""
    if os.path.exists(PROFILE_DRAFT) and not draft:
        banner = ('<div class="banner">A <strong>profile.draft.yaml</strong> is awaiting '
                  'review. <a href="/profile?draft=1">View the draft</a> &mdash; promote it '
                  'with <code>cp profile.draft.yaml profile.yaml</code>.</div>')
    if draft:
        return file_view_inner(
            "Profile draft", PROFILE_DRAFT,
            "The bootstrap's proposed profile, not yet approved. <a href=\"/profile\">"
            "View the approved profile</a>.",
            "No profile.draft.yaml present.")
    return file_view_inner(
        "Profile", PROFILE,
        "The approved profile the monitor scores against (read-only).",
        "No profile.yaml yet &mdash; run bootstrap, then promote the draft.", banner)


def config_inner():
    return file_view_inner(
        "Configuration", CONFIG,
        "The live monitor configuration (read-only). Edit the file on disk to change it.",
        "No monitor-config.yaml found &mdash; copy monitor-config.example.yaml to start.")


# ----------------------------------------------------------------------------- server

class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="text/html; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _redirect(self, location):
        self.send_response(303)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):  # noqa: N802
        u = urlparse(self.path)
        q = parse_qs(u.query)
        path = u.path
        if path in ("/", "/index.html"):
            self._send(200, shell("/", overview_inner()))
        elif path == "/reports":
            self._send(200, shell("/reports", reports_inner(q)))
        elif path == "/review":
            self._send(200, shell("/review", review_inner()))
        elif path == "/profile":
            self._send(200, shell("/profile", profile_inner(q)))
        elif path == "/config":
            self._send(200, shell("/config", config_inner()))
        elif path == "/grade":
            rid = (q.get("id") or [""])[0]
            verdict = (q.get("v") or [""])[0]
            item = next((i for i in recent_items() if str(i.get("id")) == rid), None)
            if item and verdict in ("up", "down"):
                record_grade(item, verdict)
                self._redirect("/review")
            else:
                self._send(400, b"bad grade request")
        else:
            self._send(404, b"not found")

    def log_message(self, *_):  # quiet
        pass


def export_static(out_path):
    """Write a standalone Overview snapshot (the old kb/index.html artifact)."""
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    body = ('<h1>Vantage Point</h1><p class="meta">generated %s &middot; '
            '<em>static snapshot &mdash; run <code>./bin/portal.sh</code> for the live '
            'portal (reports, review, profile, config)</em></p>%s'
            % (esc(datetime.now().strftime("%Y-%m-%d %H:%M")), overview_inner(static=True)))
    tmp = out_path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(shell("/", body))
    os.replace(tmp, out_path)
    print("[portal] wrote %s" % out_path)


def main():
    argv = sys.argv[1:]
    if argv and argv[0] in ("-h", "--help"):
        print(__doc__)
        return
    if argv and argv[0] == "--export":
        out = argv[1] if len(argv) > 1 else os.path.join(KB, "index.html")
        export_static(out)
        return
    port = 8000
    if argv:
        if not argv[0].isdigit():
            print("usage: portal.py [PORT | --export [OUT]]", file=sys.stderr)
            sys.exit(2)
        port = int(argv[0])
    httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print("[portal] http://localhost:%d/  (Ctrl-C to stop)" % port, file=sys.stderr)
    print("[portal] over SSH:  ssh -L %d:localhost:%d you@host" % (port, port), file=sys.stderr)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
