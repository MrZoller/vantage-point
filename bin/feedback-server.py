#!/usr/bin/env python3
"""feedback-server.py [port] -- a tiny localhost web UI for grading surfaced items.

Lists recent surfaced items from state/seen.jsonl with thumbs-up / thumbs-down
buttons. Clicking records the grade (with the item's full context) to
state/feedback.jsonl, which the next bootstrap reads as calibration so the
relevance rubric learns your taste. Bind is localhost-only by design -- reach it
over an SSH-forwarded port or VS Code Remote, exactly like `dashboard.sh --serve`.

Usage: python3 bin/feedback-server.py [PORT]   (default 8000; Ctrl-C to stop)
Stdlib only.
"""
import html
import json
import re
import sys
import os
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def resolve_state_file():
    """Resolve monitoring.state_file the same way bin/monitor.sh does.

    monitor.sh honors a configured dedup path (default state/seen.jsonl), so the
    review UI must read the SAME file or it shows nothing when state_file is
    relocated. We mirror the cfg_get awk helper with a minimal block/key scan
    (no YAML lib, per the repo's dependency-light convention).
    """
    cfg = os.path.join(ROOT, "monitor-config.yaml")
    value = ""
    try:
        with open(cfg, encoding="utf-8") as f:
            in_block = False
            for line in f:
                line = line.rstrip("\n")
                if not in_block:
                    if re.match(r"^monitoring:[ \t]*(#.*)?$", line):
                        in_block = True
                    continue
                if line and line[0] not in " \t#":   # an unindented line ends the block
                    break
                parts = line.split()
                if parts and parts[0] == "state_file:":
                    value = line.split("state_file:", 1)[1]
                    value = re.sub(r"\s+#.*$", "", value)        # drop a trailing comment
                    value = re.sub(r"\s+", "", value)            # cfg_get strips whitespace
                    value = value.replace('"', "").replace("'", "")
                    break
    except FileNotFoundError:
        pass
    if not value:
        value = "state/seen.jsonl"
    if value.startswith("./"):                                   # normalize like monitor.sh
        value = value[2:]
    return os.path.join(ROOT, value)


SEEN = resolve_state_file()
FEEDBACK = os.path.join(ROOT, "state", "feedback.jsonl")
MAX_ITEMS = 60


def safe_url(u):
    """Only http/https are safe in a rendered href. Reject javascript:/data:/etc.

    `url` comes from agent-written state/seen.jsonl (semi-trusted, LLM-derived from
    web sweeps), so a value like `javascript:...` would otherwise become a clickable
    link that executes on click. Returns the url if safe, else "" (link is dropped).
    """
    u = str(u).strip()
    return u if u.lower().startswith(("http://", "https://")) else ""


def read_jsonl(path):
    """Parse a JSONL file, skipping malformed lines (append-only, agent-written)."""
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
                if isinstance(obj, dict):   # skip valid-JSON-but-non-object lines (null, [], "x")
                    out.append(obj)
    except FileNotFoundError:
        pass
    return out


def recent_items():
    """Most-recent surfaced items (have an id + title; not dropped)."""
    items, seen_ids = [], set()
    for rec in reversed(read_jsonl(SEEN)):
        rid, title = rec.get("id"), rec.get("title")
        if not rid or not title or rec.get("signal") == "dropped":
            continue
        if rid in seen_ids:
            continue
        seen_ids.add(rid)
        items.append(rec)
        if len(items) >= MAX_ITEMS:
            break
    return items


def _ts(rec):
    """A sortable timestamp string; a missing or non-string value sorts earliest.

    The log can be hand-edited, so a row may carry "timestamp": null; coerce to ""
    rather than letting None >= str raise TypeError on the verdict lookup.
    """
    t = rec.get("timestamp")
    return t if isinstance(t, str) else ""


def latest_verdicts():
    """id -> most recent verdict (by timestamp), from the feedback log.

    The log is append-only, but pick by timestamp rather than file order so a manual
    edit/merge that reorders rows still surfaces the genuinely latest grade. ISO-8601
    UTC timestamps compare lexicographically; ties keep the later line.
    """
    latest = {}   # id -> record
    for rec in read_jsonl(FEEDBACK):
        rid = rec.get("id")
        if not rid:
            continue
        prev = latest.get(rid)
        if prev is None or _ts(rec) >= _ts(prev):
            latest[rid] = rec
    return {rid: rec.get("verdict") for rid, rec in latest.items()}


def record(item, verdict):
    rec = {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "id": item.get("id"),
        "verdict": verdict,
        "title": item.get("title"),
        "url": item.get("url"),
        "signal": item.get("signal"),
        "score": item.get("score"),
        "so_what": item.get("so_what"),
    }
    os.makedirs(os.path.dirname(FEEDBACK), exist_ok=True)
    with open(FEEDBACK, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")


PAGE_HEAD = """<!DOCTYPE html><html><head><meta charset="utf-8">
<title>Vantage Point - grade</title><style>
 body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
   line-height:1.45;color:#1a1a1a;max-width:760px;margin:0 auto;padding:24px}
 h1{font-size:1.4em}.muted{color:#888}.item{border-bottom:1px solid #eee;padding:12px 0}
 .sig{font-size:.8em;text-transform:uppercase;letter-spacing:.03em;color:#555}
 .grade a{text-decoration:none;font-size:1.3em;padding:2px 8px;border:1px solid #ddd;border-radius:6px;margin-right:6px}
 .on{background:#0b66c3;border-color:#0b66c3}.verdict{font-size:.85em;color:#0b66c3;margin-left:6px}
 a{color:#0b66c3}</style></head><body>
<h1>Grade surfaced items</h1>
<p class="muted">Your thumbs feed <code>state/feedback.jsonl</code>; the next bootstrap calibrates the rubric from it.</p>
"""
PAGE_FOOT = "</body></html>"


def render(items, verdicts, just=None):
    parts = [PAGE_HEAD]
    if just:
        parts.append('<p class="verdict">Recorded: %s -> %s</p>'
                     % (html.escape(str(just[0])), html.escape(str(just[1]))))
    if not items:
        parts.append('<p class="muted">No surfaced items yet.</p>')
    for it in items:
        rid = html.escape(str(it.get("id")))
        v = verdicts.get(it.get("id"))
        up_on = " on" if v == "up" else ""
        down_on = " on" if v == "down" else ""
        parts.append('<div class="item"><div class="sig">%s &middot; score %s</div>'
                     % (html.escape(str(it.get("signal", "?"))), html.escape(str(it.get("score", "?")))))
        parts.append("<div><strong>%s</strong></div>" % html.escape(str(it.get("title", ""))))
        if it.get("so_what"):
            parts.append('<div class="muted">%s</div>' % html.escape(str(it["so_what"])))
        parts.append('<div class="grade">'
                     '<a class="up%s" href="/grade?id=%s&v=up" title="relevant">&#128077;</a>'
                     '<a class="down%s" href="/grade?id=%s&v=down" title="not relevant">&#128078;</a>'
                     % (up_on, rid, down_on, rid))
        link = safe_url(it.get("url"))
        if link:
            parts.append('<a href="%s" target="_blank" rel="noopener noreferrer">source</a>'
                         % html.escape(link))
        if v:
            parts.append('<span class="verdict">graded: %s</span>' % html.escape(v))
        parts.append("</div></div>")
    parts.append(PAGE_FOOT)
    return "".join(parts).encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="text/html; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        u = urlparse(self.path)
        if u.path in ("/", "/index.html"):
            self._send(200, render(recent_items(), latest_verdicts()))
            return
        if u.path == "/grade":
            q = parse_qs(u.query)
            rid = (q.get("id") or [""])[0]
            verdict = (q.get("v") or [""])[0]
            items = recent_items()
            item = next((i for i in items if str(i.get("id")) == rid), None)
            if item and verdict in ("up", "down"):
                record(item, verdict)
                self._send(200, render(recent_items(), latest_verdicts(), just=(rid, verdict)))
            else:
                self._send(400, b"bad grade request")
            return
        self._send(404, b"not found")

    def log_message(self, *_):  # quiet
        pass


def main():
    port = 8000
    if len(sys.argv) > 1:
        if not sys.argv[1].isdigit():
            print("usage: feedback-server.py [PORT]", file=sys.stderr)
            sys.exit(2)
        port = int(sys.argv[1])
    httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print("[feedback] grading UI at http://localhost:%d/  (Ctrl-C to stop)" % port, file=sys.stderr)
    print("[feedback] over SSH:  ssh -L %d:localhost:%d you@host" % (port, port), file=sys.stderr)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
