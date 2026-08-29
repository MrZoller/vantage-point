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
import difflib
import hashlib
import html
import json
import math
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone, timedelta, date
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, quote

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG = os.path.join(ROOT, "monitor-config.yaml")
FEEDBACK = os.path.join(ROOT, "state", "feedback.jsonl")
FEEDHEALTH = os.path.join(ROOT, "state", "feedhealth.json")
OBS = os.path.join(ROOT, "state", "observations.jsonl")
HORIZON = os.path.join(ROOT, "state", "horizon.jsonl")
RUNS = os.path.join(ROOT, "state", "runs.log")
KB = os.path.join(ROOT, "kb")
PROFILE = os.path.join(ROOT, "profile.yaml")
PROFILE_DRAFT = os.path.join(ROOT, "profile.draft.yaml")
# Human-readable digests the bootstrap writes alongside the YAML. Rendered like the
# bootstrap review email when present; the YAML stays the source of truth.
PROFILE_SUMMARY = os.path.join(ROOT, "profile.summary.md")
PROFILE_DRAFT_SUMMARY = os.path.join(ROOT, "profile.draft.summary.md")
# Rubric backtest: a point-in-time artifact of the refresh scoring pass (bootstrap.sh
# + bin/backtest.py) -- how the draft rubric scores items you already graded.
PROFILE_DRAFT_BACKTEST = os.path.join(ROOT, "profile.draft.backtest.md")
# Deep-research bootstrap review aids (bootstrap.sh): the deterministic draft-feed
# verification (fetch.py --verify) and the adversarial challenge report (models.challenge).
PROFILE_DRAFT_FEEDCHECK = os.path.join(ROOT, "profile.draft.feedcheck.md")
PROFILE_DRAFT_CHALLENGE = os.path.join(ROOT, "profile.draft.challenge.md")
MAX_ITEMS = 60
MAX_EVENTS = 12
MAX_REPORTS = 30

# Visual language shared with the HTML email (bin/email-lib.sh): same accent, surfaces,
# and type so the portal and the inbox feel like one product.
ACCENT = "#2f5bea"

# Brand mark (the same arc-over-summit logo embedded in emails), inlined as SVG so the
# portal stays self-contained - no external asset, works offline and under --export.
LOGO_SVG = (
    '<svg class="brand-mark" width="30" height="30" viewBox="0 0 64 64"'
    ' xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Vantage Point logo">'
    '<path d="M6 36 A26 26 0 0 1 58 36 L48 36 A16 16 0 0 0 16 36 Z" fill="#2f5bea"/>'
    '<path d="M32 23 L53 53 L11 53 Z" fill="#1f2933"/></svg>'
)

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
.brand{display:flex;align-items:center;gap:11px;font-weight:700;color:#10151f;
  font-size:17px;letter-spacing:.01em}
.brand-mark{flex:none;display:block}
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
.feedurl{font-size:12px;word-break:break-all}
.st-bad{color:#d6455d;font-weight:600}.st-warn{color:#b45309;font-weight:600}
.num{font-variant-numeric:tabular-nums}.muted{color:var(--muted)}
.viz{max-width:100%;height:auto;display:block}
.viz text.cal-m{fill:#9aa3af;font-size:9px;font-family:inherit}
.sublabel{font-size:12px;color:var(--muted);margin:0 0 6px}
.legend{display:flex;gap:14px;flex-wrap:wrap;margin-top:8px;font-size:11px;color:var(--muted);align-items:center}
.legend .lg{display:inline-flex;align-items:center;gap:5px}
.legend .sw{width:11px;height:11px;border-radius:3px;display:inline-block}
ul.events{list-style:none;padding:0;margin:0}
ul.events li{padding:7px 0;border-bottom:1px solid var(--line);font-size:14px}
ul.events li:last-child{border:0}
.reportlist{list-style:none;padding:0;margin:0}
.reportlist li{padding:9px 0;border-bottom:1px solid var(--line)}
.reportlist li:last-child{border:0}
.reportlist .tag{display:inline-block;font-size:10px;font-weight:700;text-transform:uppercase;
  letter-spacing:.05em;color:var(--accent);background:var(--soft);border-radius:5px;
  padding:1px 7px;margin-right:8px}
.item{border-bottom:1px solid var(--line);padding:14px 0;scroll-margin-top:80px}.item:last-child{border:0}
.sig{font-size:11px;text-transform:uppercase;letter-spacing:.04em;color:var(--muted)}
.grade{margin-top:8px;display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.grade a.btn{font-size:1.25em;text-decoration:none;padding:2px 10px;border:1px solid var(--line);
  border-radius:7px;line-height:1.6}
.grade a.btn.on{background:var(--accent);border-color:var(--accent)}
.verdict{font-size:.85em;color:var(--accent)}
.missed{display:flex;gap:8px;flex-wrap:wrap;margin-top:8px}
.missed input{flex:2;min-width:220px;padding:7px 10px;border:1px solid var(--line);
  border-radius:7px;font:inherit;font-size:14px}
.missed input[name=note]{flex:1;min-width:160px}
.missed button{padding:7px 16px;border:0;border-radius:7px;background:var(--accent);
  color:#fff;font:inherit;font-size:14px;font-weight:600;cursor:pointer}
.banner{background:var(--soft);border:1px solid #d6e0ff;border-left:4px solid var(--accent);
  border-radius:0 8px 8px 0;padding:12px 16px;margin:0 0 18px;font-size:14px}
.note{font-size:12px;color:var(--muted);margin-top:6px}
pre.yaml{background:#0f172a;color:#e2e8f0;padding:18px 20px;border-radius:10px;overflow-x:auto;
  font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:13px;line-height:1.5;margin:0}
pre.yaml .k{color:#7cc5ff}pre.yaml .c{color:#64748b;font-style:italic}
pre.yaml .da{color:#7ee2a8}pre.yaml .dr{color:#f8a1ae}
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
/* Print -> "Save as PDF": drop the chrome, flatten cards, keep reports from splitting
   mid-item, and start each report on its own page in the combined view. */
@media print{
  .topbar,.legend,.noprint{display:none!important}
  body{background:#fff}
  .wrap{max-width:none;padding:0}
  .card{box-shadow:none;border:0;padding:0;margin:0 0 18px}
  .item,.body table,.body tr,.body blockquote{break-inside:avoid}
  .printreport{break-before:page}.printreport:first-of-type{break-before:auto}
  a{color:inherit;text-decoration:none}
}
"""

NAV = [("/", "Overview"), ("/reports", "Reports"), ("/entities", "Entities"),
       ("/review", "Review"), ("/profile", "Profile"), ("/config", "Config")]


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


def cfg_get_text(block, key, path=CONFIG):
    """Like cfg_get but preserves internal spaces (for human-readable values such as
    subject.name) -- mirrors bin/config-lib.sh's cfg_get_text: trims the ends, unwraps a
    surrounding quote pair, or for an unquoted value drops only a real trailing comment."""
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
                    v = line.split(key + ":", 1)[1].strip()
                    if v[:1] == '"':
                        v = re.sub(r'"\s*(#.*)?$', "", v[1:]).replace('\\"', '"')
                    elif v[:1] == "'":
                        v = re.sub(r"'\s*(#.*)?$", "", v[1:]).replace("''", "'")
                    else:
                        v = re.sub(r"\s+#.*$", "", v).rstrip()
                    value = v
                    break
    except FileNotFoundError:
        pass
    return value


def cfg_get_bool(block, key, default):
    """A truthy/falsey config flag (mirrors bin/config-lib.sh's cfg_get_bool). An
    absent/blank value returns `default`, so callers match the monitor's defaults."""
    v = cfg_get(block, key).strip().lower()
    if not v:
        return default
    return v in ("1", "true", "yes", "on")


def horizon_enabled():
    """Whether the forward radar is on, exactly as bin/monitor.sh decides it: on by
    default when tracking is enabled, off when tracking.enabled or tracking.horizon is
    false -- so a disabled radar shows no Coming up card / dossier rows in the portal."""
    return cfg_get_bool("tracking", "enabled", True) \
        and cfg_get_bool("tracking", "horizon", True)


def quiet_enabled():
    """Whether quiet detection is on, exactly as bin/monitor.sh decides it: on by
    default when tracking is enabled, off when tracking.enabled or tracking.quiet is
    false -- so a disabled feature shows no Cadence line in the dossiers."""
    return cfg_get_bool("tracking", "enabled", True) \
        and cfg_get_bool("tracking", "quiet", True)


_CADENCE_MOD = None

def _cadence_mod():
    """bin/cadence.py loaded as a module (cached), so the dossier's Cadence line shows
    the same baseline arithmetic the monitor flags with. Loaded by path from this
    file's directory -- robust to how portal.py itself was loaded -- and a standalone
    portal.py copy (no sibling cadence.py) degrades to no Cadence line, not a crash."""
    global _CADENCE_MOD
    if _CADENCE_MOD is None:
        try:
            import importlib.util
            path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cadence.py")
            spec = importlib.util.spec_from_file_location("vp_cadence", path)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            _CADENCE_MOD = mod
        except Exception:
            _CADENCE_MOD = False
    return _CADENCE_MOD or None


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


def _is_number(v):
    """A finite real number. Excludes bools (a JSON bool is an int in Python) and the
    NaN/Infinity tokens json.loads accepts but which can't be plotted."""
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def spark(values):
    """Unicode sparkline (U+2581..U+2588) for a numeric series, built from code points
    at runtime so this file stays ASCII. Non-finite/non-numeric values are dropped, and
    we scale over the last-30 window we actually render so a stale outlier outside the
    visible window can't flatten the current sparkline."""
    nums = [v for v in values if _is_number(v)][-30:]
    if not nums:
        return ""
    lo, hi = min(nums), max(nums)
    rng = hi - lo
    out = []
    for v in nums:
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
        if metric == "event" or not _is_number(value):
            continue
        entity = rec.get("entity")
        # entity/metric must be non-empty strings: a non-scalar (list/dict) would be
        # unhashable as a dict key and crash the page; skip it like any malformed row.
        if not isinstance(entity, str) or not entity or not isinstance(metric, str):
            continue
        groups.setdefault((entity, metric), []).append(rec)
    rows = []
    for (entity, metric), recs in groups.items():
        # Sort by a coerced timestamp so a missing/null ts sorts earliest (empty string)
        # rather than as "None" -- a malformed row must not become the displayed latest.
        recs.sort(key=_ts)
        last = recs[-1]
        rows.append({
            "entity": entity, "metric": metric,
            "latest": last.get("value"), "unit": last.get("unit") or "",
            "as_of": _ts(last)[:10],
            "series": [r.get("value") for r in recs],
        })
    rows.sort(key=lambda r: (str(r["entity"]), str(r["metric"])))
    return rows


def recent_events():
    events = [r for r in read_jsonl(OBS) if r.get("metric") == "event"]
    events.sort(key=_ts, reverse=True)
    return events[:MAX_EVENTS]


# ----------------------------------------------------------------- entity dossiers
# Reports are perishable; what's KNOWN about an entity should compound. These views
# assemble everything on file per tracked entity -- metric series, the event
# timeline, and the surfaced items that concerned it -- into one accumulating page.

def _item_entities(rec):
    """The tracked entities an item record was tagged with (newer records carry an
    `entities` list; anything malformed reads as untagged)."""
    ents = rec.get("entities")
    if not isinstance(ents, list):
        return []
    return [e for e in ents if isinstance(e, str) and e]


def _entity_word_re(name):
    """Whole-token matcher for an entity name (lookarounds, not bare substring),
    so a short entity like "AI" can't match every item containing "paid"."""
    return re.compile(r"(?<!\w)" + re.escape(str(name).lower()) + r"(?!\w)")


def all_entities():
    """Every entity on file -- observed in observations.jsonl or tagged on a surfaced
    item -- with item/observation counts and the latest activity date. Items are
    counted with the SAME matching the dossier uses (explicit `entities` tags plus
    the whole-token legacy name match over title/so_what), so the index can't show
    0 items while the dossier page lists some."""
    agg = {}

    def row(name):
        return agg.setdefault(name, {"name": name, "items": 0, "observations": 0, "last": ""})

    for rec in read_jsonl(OBS):
        ent = rec.get("entity")
        if not isinstance(ent, str) or not ent:
            continue
        r = row(ent)
        r["observations"] += 1
        r["last"] = max(r["last"], _ts(rec)[:10])

    # Newest record per id, like entity_items -- so the two views stay consistent.
    items, ids = [], set()
    for rec in reversed(read_jsonl(SEEN)):
        rid = rec.get("id")
        if not isinstance(rid, str) or not rid or rid in ids or rec.get("signal") == "dropped":
            continue
        ids.add(rid)
        items.append(rec)
    for rec in items:                            # tags can introduce new entities
        for ent in _item_entities(rec):
            row(ent)
    # Forward-radar expectations can name an entity not otherwise on file; register it
    # (and bump its last-activity) so its dossier -- which lists its expectations -- is
    # reachable from the index.
    for rec in _latest_horizon().values():
        ent = rec.get("entity")
        if isinstance(ent, str) and ent:
            r = row(ent)
            r["last"] = max(r["last"], _ts(rec)[:10])
    matchers = {name: _entity_word_re(name) for name in agg}
    for rec in items:
        d = rec.get("date")
        d = d if isinstance(d, str) else ""
        tags = {e.lower() for e in _item_entities(rec)}
        blob = ("%s %s" % (rec.get("title", ""), rec.get("so_what", ""))).lower()
        for name, word in matchers.items():
            if str(name).lower() in tags or word.search(blob):
                r = agg[name]
                r["items"] += 1
                r["last"] = max(r["last"], d)
    return sorted(agg.values(), key=lambda r: str(r["name"]).lower())


def entity_items(name):
    """Surfaced items about an entity, newest first: tagged with it via `entities`,
    or -- for items recorded before tagging existed -- naming it in title/so_what.
    The legacy name match requires whole tokens (lookarounds, not bare substring), so
    a short entity like "AI" can't pull in every item containing "paid"."""
    needle = str(name).lower()
    word = _entity_word_re(name)
    items, ids = [], set()
    for rec in reversed(read_jsonl(SEEN)):
        rid = rec.get("id")
        if not isinstance(rid, str) or not rid or rid in ids or rec.get("signal") == "dropped":
            continue
        tagged = any(e.lower() == needle for e in _item_entities(rec))
        blob = "%s %s" % (rec.get("title", ""), rec.get("so_what", ""))
        if tagged or word.search(blob.lower()):
            ids.add(rid)
            items.append(rec)
        if len(items) >= MAX_ITEMS:
            break
    return items


def entity_events(name):
    events = [r for r in read_jsonl(OBS)
              if r.get("entity") == name and r.get("metric") == "event"]
    events.sort(key=_ts, reverse=True)
    return events[:30]


def entity_cadence(name):
    """Cadence lines for a dossier: this entity's per-event_type baselines (from
    bin/cadence.py, the same arithmetic the monitor flags with), each annotated with
    its current silence and whether that silence passes the quiet threshold. Empty
    when quiet detection is off, cadence.py isn't beside this file, or the entity
    has too few events for a baseline."""
    if not quiet_enabled():
        return []
    mod = _cadence_mod()
    if mod is None:
        return []
    try:
        factor = float(cfg_get("tracking", "quiet_factor") or 3)
    except ValueError:
        factor = 3.0
    if not factor > 0:
        factor = 3.0
    try:
        min_events = max(1, int(cfg_get("tracking", "quiet_min_events") or 4))
    except ValueError:
        min_events = 4
    today = datetime.now(timezone.utc).date()
    rows = []
    for b in mod.baselines(OBS, min_events):
        if b["entity"] != name:
            continue
        silence = (today - date.fromisoformat(b["last_seen"])).days
        med = b["median_gap_days"]
        rows.append({
            "event_type": b["event_type"],
            "n_events": b["n_events"],
            "median_gap_days": int(med) if float(med).is_integer() else round(med, 1),
            "last_seen": b["last_seen"],
            "silence_days": silence,
            "quiet": silence >= mod.quiet_threshold(med, factor),
        })
    return rows


# ------------------------------------------------------------------ activity visuals
# Server-rendered inline SVG (no JS, no deps) so it works under the strict CSP and the
# repo's dependency-light rule. Built from the `date` (YYYY-MM-DD) + `signal` fields on
# each surfaced item in seen.jsonl.

CAL_WEEKS = 13                                   # ~a quarter of history
CAL_LEVELS = ["#ebedf0", "#cdd8fb", "#9db4f6", "#5f82ef", "#2f5bea"]  # 0..4, accent ramp
SIG_ORDER = ["opportunity", "shift", "threat"]   # stack bottom -> top
SIG_COLORS = {"opportunity": "#1e9e6a", "shift": "#2f5bea", "threat": "#d6455d"}


def _surfaced_by_date():
    """date(YYYY-MM-DD) -> {signal: count} for surfaced (non-dropped) items in seen.jsonl.
    Rows without a well-formed date are skipped, like any malformed agent output."""
    out = {}
    for rec in read_jsonl(SEEN):
        sig = rec.get("signal")
        if sig == "dropped":
            continue
        d = rec.get("date")
        if not (isinstance(d, str) and re.match(r"^\d{4}-\d{2}-\d{2}$", d)):
            continue
        # A non-scalar signal would be an unhashable dict key; coerce it to "" so the
        # row still counts toward the day's total but is excluded from the signal mix.
        key = sig if isinstance(sig, str) else ""
        out.setdefault(d, {})
        out[d][key] = out[d].get(key, 0) + 1
    return out


def _week_grid():
    """(start_sunday, weeks, today) for a CAL_WEEKS window ending today, columns aligned
    to Sunday so the calendar and the weekly signal-mix share one time axis."""
    today = datetime.now(timezone.utc).date()
    start = today - timedelta(days=CAL_WEEKS * 7 - 1)
    start -= timedelta(days=(start.weekday() + 1) % 7)   # weekday(): Mon=0..Sun=6 -> snap to Sunday
    return start, (today - start).days // 7 + 1, today


def _legend(items):  # items: [(color, label), ...]
    spans = "".join('<span class="lg"><span class="sw" style="background:%s"></span>%s</span>'
                    % (c, esc(label)) for c, label in items)
    return '<div class="legend">%s</div>' % spans


def _cal_level(count, mx):
    if count <= 0:
        return 0
    if mx <= 1:
        return len(CAL_LEVELS) - 1
    return 1 + min(len(CAL_LEVELS) - 2, (count - 1) * (len(CAL_LEVELS) - 1) // mx)


def activity_calendar():
    """GitHub-style heatmap: one cell per day, shaded by items surfaced that day."""
    by_date = _surfaced_by_date()
    if not by_date:
        return ""
    start, weeks, today = _week_grid()
    # Count + scale over only the days we actually render, so an out-of-window (older or
    # future) high-volume day can't compress the visible color scale; if nothing falls in
    # the window the card is omitted rather than rendered all-zero.
    totals = {}
    for ds, sigs in by_date.items():
        try:
            dd = date.fromisoformat(ds)
        except ValueError:
            continue
        if start <= dd <= today:
            totals[ds] = sum(sigs.values())
    mx = max(totals.values()) if totals else 0
    if mx == 0:
        return ""
    cell, gap, top = 13, 3, 18
    step = cell + gap
    w, h = weeks * step, top + 7 * step
    cells, months, last_month = [], [], None
    d = start
    while d <= today:
        col = (d - start).days // 7
        row = (d.weekday() + 1) % 7              # Sunday = 0
        ds = d.isoformat()
        c = totals.get(ds, 0)
        label = "%s: %d item%s" % (ds, c, "" if c == 1 else "s")
        cells.append('<rect x="%d" y="%d" width="%d" height="%d" rx="2" fill="%s">'
                     '<title>%s</title></rect>'
                     % (col * step, top + row * step, cell, cell,
                        CAL_LEVELS[_cal_level(c, mx)], esc(label)))
        if row == 0:                            # column starts on a Sunday -> month label
            m = d.strftime("%b")
            if m != last_month:
                months.append('<text x="%d" y="12" class="cal-m">%s</text>' % (col * step, esc(m)))
                last_month = m
        d += timedelta(days=1)
    svg = ('<svg class="viz" viewBox="0 0 %d %d" width="%d" height="%d" '
           'role="img" aria-label="Items surfaced per day">%s%s</svg>'
           % (w, h, w, h, "".join(months), "".join(cells)))
    ramp = _legend([(CAL_LEVELS[0], "less")] + [(c, "") for c in CAL_LEVELS[1:-1]]
                   + [(CAL_LEVELS[-1], "more")])
    return svg + ramp


def signal_mix():
    """Weekly stacked bars of opportunity / shift / threat over the same window."""
    by_date = _surfaced_by_date()
    if not by_date:
        return ""
    start, weeks, today = _week_grid()
    wk = [dict() for _ in range(weeks)]
    for ds, sigs in by_date.items():
        try:
            d = date.fromisoformat(ds)
        except ValueError:
            continue
        if start <= d <= today:
            i = (d - start).days // 7
            for sig, c in sigs.items():
                wk[i][sig] = wk[i].get(sig, 0) + c
    totals = [sum(w.get(s, 0) for s in SIG_ORDER) for w in wk]
    mx = max(totals) if totals else 0
    if mx == 0:                                  # only unknown-signal items -> nothing to stack
        return ""
    barw, gap, top, ph = 14, 6, 6, 90
    step = barw + gap
    w, h = weeks * step, top + ph + 16
    bars, last_month = [], None
    for i, counts in enumerate(wk):
        x, y = i * step, top + ph
        for sig in SIG_ORDER:
            c = counts.get(sig, 0)
            if c <= 0:
                continue
            seg = max(2, round(c / mx * ph))
            y -= seg
            bars.append('<rect x="%d" y="%d" width="%d" height="%d" fill="%s">'
                        '<title>week of %s: %d %s</title></rect>'
                        % (x, y, barw, seg, SIG_COLORS[sig],
                           (start + timedelta(days=i * 7)).isoformat(), c, esc(sig)))
        m = (start + timedelta(days=i * 7)).strftime("%b")
        if m != last_month:
            bars.append('<text x="%d" y="%d" class="cal-m">%s</text>' % (x, h - 3, esc(m)))
            last_month = m
    svg = ('<svg class="viz" viewBox="0 0 %d %d" width="%d" height="%d" '
           'role="img" aria-label="Signal mix by week">%s</svg>'
           % (w, h, w, h, "".join(bars)))
    return svg + _legend([(SIG_COLORS[s], s) for s in SIG_ORDER])


# ------------------------------------------------------------------ calibration stats
# "Does grading actually make it sharper?" -- measured, not asserted. Precision is
# computed over GRADED items only: an ungraded item is unknown, not an implicit
# positive, so the grading COVERAGE is always reported alongside to keep the
# headline honest. Items are bucketed by the date they were surfaced.

def _surfaced_index():
    """id -> {date, source} for surfaced (non-dropped) items in seen.jsonl.
    First record per id wins (a rerun may append the same id again)."""
    out = {}
    for rec in read_jsonl(SEEN):
        rid = rec.get("id")
        if not isinstance(rid, str) or not rid or rid in out or rec.get("signal") == "dropped":
            continue
        d = rec.get("date")
        src = rec.get("source")
        out[rid] = {
            "date": d if isinstance(d, str) and re.match(r"^\d{4}-\d{2}-\d{2}$", d) else "",
            "source": src if isinstance(src, str) else "",
        }
    return out


def _grade_date(rid, rec, surfaced):
    """The YYYY-MM-DD bucket for a graded item: the date it was surfaced, falling
    back to the grade's own timestamp if the item has been pruned from seen.jsonl."""
    return surfaced.get(rid, {}).get("date") or _ts(rec)[:10]


def calibration_stats():
    """(surfaced, ups, downs) over items surfaced in the last 30 days.

    A graded item whose seen.jsonl record was pruned (state_max_lines) still counts,
    bucketed by its grade timestamp -- the same fallback precision_chart uses -- so
    the headline numbers can't silently drop valid recent grades on high-volume or
    low-retention installs."""
    surfaced = _surfaced_index()
    graded = _latest_feedback()
    cutoff = (datetime.now(timezone.utc).date() - timedelta(days=30)).isoformat()
    n = ups = downs = 0
    for rid, info in surfaced.items():
        if not info["date"] or info["date"] < cutoff:
            continue
        n += 1
        verdict = graded.get(rid, {}).get("verdict")
        if verdict == "up":
            ups += 1
        elif verdict == "down":
            downs += 1
    for rid, rec in graded.items():
        if rid in surfaced:
            continue
        verdict = rec.get("verdict")
        if verdict not in ("up", "down"):
            continue
        d = _ts(rec)[:10]
        if d and d >= cutoff:
            n += 1                               # it was surfaced once, then pruned
            if verdict == "up":
                ups += 1
            else:
                downs += 1
    return n, ups, downs


def precision_chart():
    """Weekly bars of precision (% thumbs-up among graded items), over the same
    window as the other Activity charts. The faint full-height track marks weeks
    that have grades; weeks without grades render nothing (unknown, not zero)."""
    surfaced = _surfaced_index()
    graded = _latest_feedback()
    if not graded:
        return ""
    start, weeks, today = _week_grid()
    wk = [[0, 0] for _ in range(weeks)]            # [ups, downs] per week
    for rid, rec in graded.items():
        verdict = rec.get("verdict")
        if verdict not in ("up", "down"):
            continue
        try:
            d = date.fromisoformat(_grade_date(rid, rec, surfaced))
        except ValueError:
            continue
        if start <= d <= today:
            i = (d - start).days // 7
            wk[i][0 if verdict == "up" else 1] += 1
    if not any(u + dn for u, dn in wk):
        return ""
    barw, gap, top, ph = 14, 6, 6, 90
    step = barw + gap
    w, h = weeks * step, top + ph + 16
    bars, last_month = [], None
    for i, (ups, downs) in enumerate(wk):
        x = i * step
        total = ups + downs
        if total:
            frac = ups / total
            seg = max(2, round(frac * ph))
            bars.append('<rect x="%d" y="%d" width="%d" height="%d" rx="2" fill="%s" '
                        'fill-opacity=".15"/>' % (x, top, barw, ph, ACCENT))
            bars.append('<rect x="%d" y="%d" width="%d" height="%d" rx="2" fill="%s">'
                        '<title>week of %s: %d%% up (%d of %d graded)</title></rect>'
                        % (x, top + ph - seg, barw, seg, ACCENT,
                           (start + timedelta(days=i * 7)).isoformat(),
                           round(frac * 100), ups, total))
        m = (start + timedelta(days=i * 7)).strftime("%b")
        if m != last_month:
            bars.append('<text x="%d" y="%d" class="cal-m">%s</text>' % (x, h - 3, esc(m)))
            last_month = m
    return ('<svg class="viz" viewBox="0 0 %d %d" width="%d" height="%d" '
            'role="img" aria-label="Precision by week">%s</svg>'
            % (w, h, w, h, "".join(bars)))


def source_stats():
    """Per-source value attribution: surfaced / graded / thumbs-up counts, busiest
    sources first (capped). Tells you which sources earn their rank -- and feeds
    the judgement call of pruning or promoting them at the next bootstrap."""
    surfaced = _surfaced_index()
    graded = _latest_feedback()
    agg = {}
    for rid, info in surfaced.items():
        src = info["source"] or "(unknown)"
        row = agg.setdefault(src, [0, 0, 0])       # surfaced, graded, ups
        row[0] += 1
        verdict = graded.get(rid, {}).get("verdict")
        if verdict in ("up", "down"):
            row[1] += 1
            if verdict == "up":
                row[2] += 1
    rows = [{"source": s, "surfaced": a[0], "graded": a[1], "ups": a[2]}
            for s, a in agg.items()]
    rows.sort(key=lambda r: (-r["surfaced"], r["source"]))
    return rows[:12]


def calibration_card(static=False):
    """The Overview's Calibration card. Omitted until the first grade exists."""
    if not _latest_feedback():
        return ""
    surfaced30, ups30, downs30 = calibration_stats()
    graded30 = ups30 + downs30
    chart = precision_chart()
    parts = ['<div class="card"><h2>Calibration</h2>']
    if graded30:
        precision = round(100 * ups30 / graded30)
        coverage = round(100 * graded30 / surfaced30) if surfaced30 else 0
        parts.append('<p class="sublabel">Last 30 days: <strong>%d%% precision</strong> '
                     '(%d up of %d graded) &middot; %d%% coverage (%d of %d surfaced '
                     'items graded)</p>' % (precision, ups30, graded30, coverage,
                                            graded30, surfaced30))
    else:
        where = "the Review tab" if static else '<a href="/review">Review</a>'
        parts.append('<p class="sublabel">No grades on the last 30 days of items '
                     '&mdash; thumb items in %s to track precision.</p>' % where)
    missed30 = missed_count_30d()
    if missed30:
        # The recall caveat: precision over surfaced items can look great while the
        # sweep quietly misses things, so reported misses sit right next to it.
        parts.append('<p class="sublabel">%d missed signal%s reported (last 30 days) '
                     '&mdash; relevant items the monitor never surfaced; the precision '
                     'figure above does not see these.</p>'
                     % (missed30, "" if missed30 == 1 else "s"))
    if chart:
        parts.append('<p class="sublabel" style="margin-top:14px">Precision by week '
                     '(graded items only)</p>%s' % chart)
    rows = [r for r in source_stats() if r["graded"]]
    if rows:
        parts.append('<p class="sublabel" style="margin-top:14px">Source hit rates '
                     '(graded items, all time)</p>')
        parts.append('<table><tr><th>Source</th><th>Surfaced</th><th>Graded</th>'
                     '<th>Thumbs-up rate</th></tr>')
        for r in rows:
            rate = '%d%% (%d/%d)' % (round(100 * r["ups"] / r["graded"]),
                                     r["ups"], r["graded"])
            parts.append('<tr><td>%s</td><td class="num">%d</td><td class="num">%d</td>'
                         '<td class="num">%s</td></tr>'
                         % (esc(r["source"]), r["surfaced"], r["graded"], rate))
        parts.append('</table>')
    parts.append('</div>')
    return "".join(parts)


# ------------------------------------------------------------------ feed health
# Coverage integrity for the deterministic sweep (Phase 11): bin/fetch.py records
# per-feed health to state/feedhealth.json each run, and this card makes rot
# visible -- a feed that 404s for weeks (failing) or returns 200 but stopped
# publishing (stale) silently shrinks recall until someone notices.

STALE_FEED_DAYS = 14


def feed_health_rows():
    """Per-feed status rows from state/feedhealth.json, problems first."""
    try:
        with open(FEEDHEALTH, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return []
    if not isinstance(data, dict):
        return []
    cutoff = (datetime.now(timezone.utc)
              - timedelta(days=STALE_FEED_DAYS)).strftime("%Y-%m-%dT%H:%M:%SZ")
    rows = []
    for feed, rec in data.items():
        if not isinstance(rec, dict) or not isinstance(feed, str):
            continue
        fails = rec.get("consecutive_failures")
        fails = fails if isinstance(fails, int) and fails >= 0 else 0
        last_ok = rec.get("last_ok")
        last_ok = last_ok if isinstance(last_ok, str) else ""
        last_entry = rec.get("last_entry")
        last_entry = last_entry if isinstance(last_entry, str) else ""
        if fails:
            status, cls, order = ("failing (%d run%s)"
                                  % (fails, "" if fails == 1 else "s"), "st-bad", 0)
        elif not last_entry:
            status, cls, order = "stale (no dated entries seen)", "st-warn", 1
        elif last_entry < cutoff:
            status, cls, order = ("stale (no new entries since %s)"
                                  % last_entry[:10], "st-warn", 1)
        else:
            status, cls, order = "ok", "muted", 2
        rows.append({"feed": feed, "status": status, "cls": cls, "order": order,
                     "last_ok": last_ok[:10], "last_entry": last_entry[:10]})
    rows.sort(key=lambda r: (r["order"], r["feed"]))
    return rows


def feed_health_card():
    """The Overview's Feed health card. Omitted until a sweep has recorded health."""
    rows = feed_health_rows()
    if not rows:
        return ""
    problems = sum(1 for r in rows if r["order"] < 2)
    label = ("all %d feeds sweeping normally" % len(rows) if not problems
             else "%d of %d feed%s need%s attention"
             % (problems, len(rows), "" if len(rows) == 1 else "s",
                "s" if problems == 1 else ""))
    parts = ['<div class="card"><h2>Feed health</h2>',
             '<p class="sublabel">The deterministic sweep&#39;s coverage &mdash; %s. '
             'A failing or stale feed is silent recall rot: fix the URL, or drop it '
             'from <code>subject.derived.feeds</code> at the next refresh.</p>'
             % esc(label),
             '<table><tr><th>Feed</th><th>Status</th><th>Last OK</th>'
             '<th>Newest entry</th></tr>']
    for r in rows:
        parts.append('<tr><td class="feedurl">%s</td><td class="%s">%s</td>'
                     '<td class="muted">%s</td><td class="muted">%s</td></tr>'
                     % (esc(r["feed"]), r["cls"], esc(r["status"]),
                        esc(r["last_ok"]) or "&mdash;",
                        esc(r["last_entry"]) or "&mdash;"))
    parts.append('</table></div>')
    return "".join(parts)


# ------------------------------------------------------------------ forward radar
# The "Coming up" surface (Phase 18): the monitor records dated, time-bounded
# expectations to state/horizon.jsonl as it sweeps, and re-checks them as they come
# due. The Overview card and each dossier's "Expected" list render that log, collapsed
# latest-row-per-id exactly like bin/horizon.py. Grace by precision mirrors horizon.py.

HORIZON_GRACE = {"day": 3, "month": 7, "quarter": 21, "half": 30, "year": 30}


def _latest_horizon():
    """id -> newest expectation record (by timestamp); the append-only log's latest row
    per id wins, mirroring bin/horizon.py. Non-string ids are skipped (unhashable/edited).
    Returns nothing when the radar is disabled, so a turned-off feature renders no card,
    dossier rows, or index entries from leftover state -- matching the monitor."""
    if not horizon_enabled():
        return {}
    latest = {}
    for rec in read_jsonl(HORIZON):
        rid = rec.get("id")
        if not isinstance(rid, str) or not rid:
            continue
        prev = latest.get(rid)
        if prev is None or _ts(rec) >= _ts(prev):
            latest[rid] = rec
    return latest


def _horizon_timing(rec):
    """(due date, days overdue as of today, past_grace) for a record, or None when the
    due date is missing/unparseable (treated as unplottable rather than crashing)."""
    due = rec.get("due")
    if not isinstance(due, str):
        return None
    try:
        d = date.fromisoformat(due[:10])
    except ValueError:
        return None
    overdue = (date.today() - d).days
    precision = rec.get("due_precision")
    grace = HORIZON_GRACE.get(precision, 30) if isinstance(precision, str) else 30
    return d, overdue, overdue > grace


def coming_up_rows():
    """Pending expectations (latest per id) for the Overview card: overdue first, then
    due, then upcoming, each sorted by due date."""
    rows = []
    for rec in _latest_horizon().values():
        if rec.get("status", "pending") != "pending":
            continue
        timing = _horizon_timing(rec)
        if timing is None:
            continue
        d, overdue, past_grace = timing
        if past_grace:
            status, cls, order = "overdue %dd" % overdue, "st-bad", 0
        elif overdue >= 0:
            status, cls, order = "due", "st-warn", 1
        else:
            status, cls, order = "upcoming", "muted", 2
        rows.append({"entity": rec.get("entity", ""), "event": rec.get("event", ""),
                     "due": d.isoformat(), "due_text": rec.get("due_text", ""),
                     "status": status, "cls": cls, "order": order, "when": d})
    rows.sort(key=lambda r: (r["order"], r["when"]))
    return rows


def coming_up_card(static=False):
    """The Overview's Coming up card (the forward radar). Omitted until an expectation
    has been recorded."""
    rows = coming_up_rows()
    if not rows:
        return ""
    overdue = sum(1 for r in rows if r["order"] == 0)
    summary = ("%d pending; %d overdue (a silent slip is itself a signal)" % (len(rows), overdue)
               if overdue else "%d pending, none overdue" % len(rows))
    parts = ['<div class="card"><h2>Coming up</h2>',
             '<p class="sublabel">Forward-dated expectations the monitor recorded from '
             'the sweep &mdash; earnings dates, announced launches, "GA in Q3" &mdash; '
             '%s.</p>' % esc(summary),
             '<table><tr><th>Due</th><th>Entity</th><th>Expected</th>'
             '<th>Status</th></tr>']
    for r in rows:
        # In the live portal the entity opens its dossier; the static export has no
        # /entity route, so it keeps plain text (like the other Overview tables).
        ent = esc(r["entity"])
        if r["entity"] and not static:
            ent = '<a href="%s">%s</a>' % (esc(entity_href(r["entity"])), ent)
        expected = esc(r["event"])
        if r["due_text"]:
            expected += ' <span class="muted">(&ldquo;%s&rdquo;)</span>' % esc(r["due_text"])
        parts.append('<tr><td class="num">%s</td><td>%s</td><td>%s</td>'
                     '<td class="%s">%s</td></tr>'
                     % (esc(r["due"]), ent, expected, r["cls"], esc(r["status"])))
    parts.append('</table></div>')
    return "".join(parts)


def entity_expectations(name):
    """This entity's expectation chain (latest row per id): pending first (overdue, then
    due, then upcoming), then the met/lapsed/withdrawn history -- so a dossier shows the
    announced -> slipped -> met arc."""
    pend, history = [], []
    for rec in _latest_horizon().values():
        if rec.get("entity") != name:
            continue
        timing = _horizon_timing(rec)
        status = rec.get("status", "pending")
        when = timing[0].isoformat() if timing else (
            rec.get("due") if isinstance(rec.get("due"), str) else "")
        out = {"event": rec.get("event", ""), "due": when,
               "due_text": rec.get("due_text", ""), "status": status,
               "source": safe_url(rec.get("source")), "note": rec.get("note", "")}
        if status == "pending" and timing is not None:
            _, overdue, past_grace = timing
            out["badge"] = ("overdue %dd" % overdue if past_grace
                            else "due" if overdue >= 0 else "upcoming")
            out["cls"] = ("st-bad" if past_grace else "st-warn" if overdue >= 0 else "muted")
            out["sort"] = (0 if past_grace else 1 if overdue >= 0 else 2, when)
            pend.append(out)
        else:
            out["badge"], out["cls"], out["sort"] = status, "muted", when
            history.append(out)
    pend.sort(key=lambda r: r["sort"])
    history.sort(key=lambda r: r["sort"], reverse=True)
    return pend + history


def list_reports():
    """Daily/weekly report basenames, newest first (names are date-prefixed)."""
    try:
        names = [n for n in os.listdir(KB) if n.endswith((".daily.md", ".weekly.md"))]
    except FileNotFoundError:
        names = []
    return sorted(names, reverse=True)


def run_stats():
    """(monitor runs in last 30d, summed cost, last-run ISO timestamp) from runs.log.

    A single monitor invocation can log several rows (triage + optional deepdive/editor),
    each stamped independently, so -- like bin/usage.sh -- we count only the triage row
    (pass missing or "triage") as a run, while still summing cost across every pass."""
    runs = read_jsonl(RUNS)
    cutoff = (datetime.now(timezone.utc) - timedelta(days=30)).strftime("%Y-%m-%dT%H:%M:%SZ")
    seen_runs, cost, last = set(), 0.0, ""
    for rec in runs:
        ts = _ts(rec)
        if ts > last:
            last = ts
        if ts and ts >= cutoff:
            c = rec.get("cost_usd")
            if _is_number(c):
                cost += c
            if rec.get("pass") in (None, "", "triage"):
                seen_runs.add((ts, rec.get("mode")))
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


def _latest_feedback():
    """id -> newest feedback record (by timestamp). Non-string ids are skipped --
    the log is agent-adjacent and hand-editable, and a non-scalar id would be an
    unhashable dict key."""
    latest = {}
    for rec in read_jsonl(FEEDBACK):
        rid = rec.get("id")
        if not isinstance(rid, str) or not rid:
            continue
        prev = latest.get(rid)
        if prev is None or _ts(rec) >= _ts(prev):
            latest[rid] = rec
    return latest


def latest_verdicts():
    """id -> newest verdict (by timestamp) from the feedback log."""
    return {rid: rec.get("verdict") for rid, rec in _latest_feedback().items()}


def _append_feedback(rec):
    os.makedirs(os.path.dirname(FEEDBACK), exist_ok=True)
    with open(FEEDBACK, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")


def record_grade(item, verdict):
    _append_feedback({
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "id": item.get("id"), "verdict": verdict,
        "title": item.get("title"), "url": item.get("url"),
        "source": item.get("source"),
        "signal": item.get("signal"), "score": item.get("score"),
        "so_what": item.get("so_what"),
    })


# ------------------------------------------------------------------ missed signals
# The recall side of calibration: thumbs can only grade what WAS surfaced, so a
# false negative is invisible to precision. A missed-signal report names a relevant
# URL the monitor never surfaced; it lands in the same feedback log (verdict
# "missed") so live calibration sees it the very next run and the next bootstrap
# folds it into the rubric and source ranking.

def missed_id(url):
    """Stable id for a missed-signal report: 8 hex chars of the URL, the same shape
    as surfaced-item ids, so re-reporting the same URL collapses to one latest row
    in dedupe-feedback rather than stacking duplicates."""
    return hashlib.sha256(url.encode("utf-8")).hexdigest()[:8]


def record_missed(url, note):
    _append_feedback({
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "id": missed_id(url), "verdict": "missed",
        "url": url, "note": note,
    })


def recent_missed(limit=10):
    """Latest missed-signal reports, newest first."""
    rows = [r for r in _latest_feedback().values() if r.get("verdict") == "missed"]
    rows.sort(key=_ts, reverse=True)
    return rows[:limit]


def missed_count_30d():
    cutoff = (datetime.now(timezone.utc).date() - timedelta(days=30)).isoformat()
    return sum(1 for r in _latest_feedback().values()
               if r.get("verdict") == "missed" and _ts(r)[:10] >= cutoff)


# ----------------------------------------------------------------------------- markdown

def _split_row(line):
    """Split a markdown table row into trimmed cells, dropping the empty edges that a
    leading/trailing pipe produces."""
    cells = line.strip().split("|")
    if cells and cells[0].strip() == "":
        cells = cells[1:]
    if cells and cells[-1].strip() == "":
        cells = cells[:-1]
    return [c.strip() for c in cells]


def _is_table_divider(line):
    """True for a GFM header divider like `|---|:--:|` (only -, :, |, space)."""
    s = line.strip()
    return "-" in s and bool(re.match(r"^\|?[\s:|-]+\|?$", s)) and "|" in s


def _light_md(md):
    """A tiny, safe markdown subset for when no pandoc/cmark is installed: headings,
    bold, links, bullet lists, blockquotes, rules, and GFM tables (the weekly watchlist).
    Everything is escaped first, so no raw HTML from the report can leak through."""
    def inline(s):
        s = esc(s)
        # Stash spans whose interior must survive verbatim past the emphasis pass, leaving
        # an opaque placeholder behind; restored at the very end. Code spans protect their
        # contents (`snake_case`/`*args`), and resolved links protect their href -- so a
        # URL like https://example.com/_id_ can't be mangled by the underscore pass.
        held = []

        def hold(frag):
            held.append(frag)
            return "\x00%d\x00" % (len(held) - 1)
        s = re.sub(r"`([^`]+)`", lambda m: hold("<code>%s</code>" % m.group(1)), s)

        def emph(t):
            # Bold before italic so the single-mark pass can't eat a `**`/`__` pair. For
            # the underscore forms, `(?<!\w)`/`(?!\w)` keeps snake_case identifiers literal
            # (GFM's intra-word rule); the `(?!\s)`/`(?<!\s)` guards skip stray ` * `.
            t = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", t)
            t = re.sub(r"(?<!\w)__(?!\s)(.+?)(?<!\s)__(?!\w)", r"<strong>\1</strong>", t)
            t = re.sub(r"\*(?!\s)([^*]+?)(?<!\s)\*", r"<em>\1</em>", t)
            t = re.sub(r"(?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w)", r"<em>\1</em>", t)
            return t

        def link(m):
            # The whole line was HTML-escaped first, so the captured URL has e.g. & as
            # &amp; already; unescape before validating/re-escaping so a query string
            # isn't double-escaped into a broken `amp;` href. Emphasis still applies to the
            # link text; the resolved anchor is held so emphasis never rewrites the href.
            url = safe_url(html.unescape(m.group(2)))
            text = emph(m.group(1))
            return hold('<a href="%s">%s</a>' % (esc(url), text)) if url else text
        s = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", link, s)
        s = emph(s)
        # Restore held fragments. A held anchor can embed an earlier (lower-index) code
        # placeholder in its text, so expand from highest index down -- each container is
        # restored before the nested placeholder it references.
        for i in range(len(held) - 1, -1, -1):
            s = s.replace("\x00%d\x00" % i, held[i])
        return s

    out, in_ul, in_bq = [], False, False

    def close():
        nonlocal in_ul, in_bq
        if in_ul:
            out.append("</ul>")
            in_ul = False
        if in_bq:
            out.append("</blockquote>")
            in_bq = False

    lines = md.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i].rstrip()
        stripped = line.strip()
        if not stripped:
            close()
            i += 1
            continue
        # GFM table: a header row followed by a `---|---` divider, then body rows.
        if "|" in line and i + 1 < len(lines) and _is_table_divider(lines[i + 1]):
            close()
            header = _split_row(line)
            out.append("<table><thead><tr>%s</tr></thead><tbody>"
                       % "".join("<th>%s</th>" % inline(c) for c in header))
            i += 2
            while i < len(lines) and "|" in lines[i] and lines[i].strip():
                out.append("<tr>%s</tr>"
                           % "".join("<td>%s</td>" % inline(c) for c in _split_row(lines[i])))
                i += 1
            out.append("</tbody></table>")
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
        elif re.match(r"^(-{3,}|\*{3,})$", stripped):
            close()
            out.append("<hr>")
        else:
            close()
            out.append("<p>%s</p>" % inline(line))
        i += 1
    close()
    return "\n".join(out)


# The renderer chain, in preference order. Each entry is asked to PROVE it neutralizes
# raw HTML before it is trusted -- see _safe_renderer().
RENDERERS = (("pandoc", ["-f", "gfm-raw_html", "-t", "html"]),
             ("cmark-gfm", ["-e", "autolink", "-e", "table", "-e",
                            "strikethrough", "-e", "tagfilter"]),
             ("cmark", []))

# Fed to a candidate renderer to see what it does with raw HTML. A renderer that leaves
# any of these live is not used, whatever its flags claim. Four probes because they
# catch different failure classes: <script> is the headline tag every filter drops;
# <img onerror=> survives GFM tagfilter, which drops script but not img; <style> is the
# tag that stays DANGEROUS under this portal's CSP (style-src 'unsafe-inline', so a
# surviving <style> can restyle or blank the whole page); and <vpcanary> is a made-up
# element no denylist has ever heard of, so a filter that strips known-bad tags while
# passing unknown raw HTML through is caught by the sentinel it cannot have listed.
# ...and in BOTH parsing contexts: CommonMark handles inline HTML and start-of-line
# HTML blocks through separate paths, so the same tags appear once inline (behind the
# "canary " prefix) and once as blank-line-delimited blocks at column 0 -- a renderer
# that suppresses only one context is rejected by the survivor from the other.
RAW_HTML_CANARY = ("canary <script>alert(1)</script> <img src=x onerror=alert(2)> "
                   "<style>p{}</style> <vpcanary>x</vpcanary>\n"
                   "\n<style>\np{}\n</style>\n"
                   "\n<vpcanary>\nblock\n</vpcanary>\n")

_RENDERER = None       # None = not probed yet; False = nothing on the chain is safe
_RENDERER_ID = None    # the winner's (path, mtime_ns, size, ino, dev) at probe time
_RENDERER_RETRY = 0.0  # monotonic deadline after which a negative verdict is re-probed
# How long "nothing on the chain is safe" is believed before looking again. A negative
# cached forever would strand a long-lived portal on the reduced-fidelity light renderer
# after a transient gap -- mid-upgrade, or a renderer installed later -- where the old
# per-call discovery recovered by itself. A bounded TTL keeps that self-healing (at most
# one probe burst per window) without re-paying the probe on every render.
NEGATIVE_TTL_SECONDS = 300.0


def _neutralizes_raw_html(cmd, args):
    """True when `cmd` demonstrably renders RAW_HTML_CANARY without live markup."""
    try:
        p = subprocess.run([cmd] + args, input=RAW_HTML_CANARY, capture_output=True,
                           text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return False
    if p.returncode != 0 or not p.stdout.strip():
        return False
    low = p.stdout.lower()
    # Any canary tag surviving as a real tag means raw HTML passed through. Match the
    # TAGS rather than attribute text like `onerror`: a renderer that escapes the canary
    # leaves the attribute behind as inert characters (&lt;img src=x onerror=...&gt;),
    # and rejecting it for that would refuse a renderer doing exactly the right thing.
    return not any(t in low for t in ("<script", "<img", "<style", "<vpcanary"))


def _renderer_id(cmd):
    """Identity of the executable `cmd` resolves to right now: its path plus the stat
    fields that change when the file is replaced. None when it no longer resolves or
    cannot be statted -- both read as "not the binary that was probed"."""
    path = shutil.which(cmd)
    if not path:
        return None
    try:
        st = os.stat(path)
    except OSError:
        return None
    return (path, st.st_mtime_ns, st.st_size, st.st_ino, st.st_dev)


def _safe_renderer():
    """First installed renderer that passes the raw-HTML canary, re-probed when the
    winning executable changes on disk.

    Asking rather than assuming is the point. cmark/cmark-gfm omit raw HTML in their
    default (no --unsafe) safe mode, and pandoc was believed to do the same once its
    raw_html extension was disabled with `-f gfm-raw_html`. It does not: pandoc's gfm
    reader accepts that flag, exits 0, and still emits a live `<script>` (measured on
    pandoc 3.9; only its `markdown` reader honours the toggle). The flag looked correct
    and the CI runners carry no pandoc, so the gap stayed invisible on every machine
    except the one that actually serves the portal. A canary cannot rot that way: a
    renderer that stops being safe simply stops being picked.

    The verdict is cached, but keyed to the winner's resolved path and stat signature:
    a probe attests to the file it ran, not to the name, and a long-lived portal can
    watch `brew upgrade` swap the binary underneath it. Each call re-stats the winner
    (microseconds, against the ~ms subprocess it guards) and a changed or vanished file
    drops the cache and re-probes. The residual window -- a swap between this check and
    the exec's own path resolution -- is microseconds instead of the portal's lifetime,
    and behind it the CSP still confines raw HTML to markup, not script. Re-probing
    every render was considered and declined: it would double the subprocess cost of
    every report view to close a window the stat check already reduces to noise."""
    global _RENDERER, _RENDERER_ID, _RENDERER_RETRY
    if _RENDERER is False and time.monotonic() >= _RENDERER_RETRY:
        _RENDERER = None   # the negative verdict has aged out -- look again
    if _RENDERER:
        if _renderer_id(_RENDERER[0]) == _RENDERER_ID:
            return _RENDERER
        # The probed file is gone or different. Fall toward the light renderer while
        # re-probing (never toward trusting the unknown binary), same as first call.
        sys.stderr.write("[portal] %s changed on disk since it was probed; "
                         "re-checking the renderer chain\n" % _RENDERER[0])
        _RENDERER = None
    if _RENDERER is None:
        _RENDERER = False
        _RENDERER_ID = None
        for cmd, args in RENDERERS:
            before = _renderer_id(cmd)
            if before is None:
                continue
            if _neutralizes_raw_html(cmd, args):
                # Accept only if the file is still the one the probe ran: a swap DURING
                # the probe would otherwise pin the new binary to the old file's verdict.
                if _renderer_id(cmd) != before:
                    continue
                _RENDERER_ID = before
                _RENDERER = (cmd, args)
                break
            # Installed but unsafe: say so once, so an operator whose reports suddenly
            # render through a different tool knows which one was skipped and why.
            sys.stderr.write("[portal] %s left raw HTML live on the canary; "
                             "skipping it\n" % cmd)
        if _RENDERER is False:
            _RENDERER_RETRY = time.monotonic() + NEGATIVE_TTL_SECONDS
    return _RENDERER


def render_markdown(md):
    """Render report markdown to an HTML fragment using the same renderer chain as the
    email (pandoc/cmark-gfm/cmark); fall back to the light renderer if none is present.

    Reports are agent-written from web sweeps, so the markdown is semi-trusted and the
    portal serves the result to a browser -- raw HTML in the source must not become live
    markup. Which renderer honours that is PROVEN per machine by _safe_renderer(), never
    assumed from a flag. The light renderer escapes everything, so falling all the way
    through is safe by construction. A strict CSP on every response (see Handler._send)
    is the defense-in-depth backstop."""
    picked = _safe_renderer()
    if picked:
        cmd, args = picked
        try:
            p = subprocess.run([cmd] + args, input=md, capture_output=True,
                               text=True, timeout=20)
            if p.returncode == 0 and p.stdout.strip():
                return p.stdout
        except (OSError, subprocess.SubprocessError):
            pass
    return _light_md(md)


# ----------------------------------------------------------------------------- views

def shell(active, inner, title=""):
    nav = "".join(
        '<a href="%s"%s>%s</a>' % (path, ' class="on"' if path == active else "", esc(label))
        for path, label in NAV)
    page_title = "Vantage Point" + (" — " + title if title else "")
    return ("<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\">"
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
            "<title>%s</title><style>%s</style></head><body>"
            "<div class=\"topbar\"><div class=\"inner\">"
            "<div class=\"brand\">%s<span><span class=\"eyebrow\">Vantage Point</span>"
            "market intelligence</span></div><nav class=\"nav\">%s</nav></div></div>"
            "<div class=\"wrap\">%s</div></body></html>"
            % (esc(page_title), CSS, LOGO_SVG, nav, inner)).encode("utf-8")


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

    cal, mix = activity_calendar(), signal_mix()
    if cal or mix:
        parts.append('<div class="card"><h2>Activity</h2>')
        if cal:
            parts.append('<p class="sublabel">Items surfaced per day</p>%s' % cal)
        if mix:
            parts.append('<p class="sublabel" style="margin-top:18px">Signal mix by week</p>%s' % mix)
        parts.append('</div>')

    parts.append(calibration_card(static=static))
    parts.append(coming_up_card(static=static))
    parts.append(feed_health_card())

    parts.append('<div class="card"><h2>Tracked entities</h2>')
    if rows:
        parts.append('<table><tr><th>Entity</th><th>Metric</th><th>Latest</th>'
                     '<th>Recent</th><th>As of</th></tr>')
        for r in rows:
            # In the live portal the entity opens its dossier; the static export has
            # no /entity route, so it keeps plain text.
            ent = esc(r["entity"]) if static else (
                '<a href="%s">%s</a>' % (esc(entity_href(r["entity"])), esc(r["entity"])))
            parts.append('<tr><td>%s</td><td>%s</td><td class="num">%s %s</td>'
                         '<td class="spark">%s</td><td class="muted">%s</td></tr>'
                         % (ent, esc(r["metric"]), esc(r["latest"]),
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
                         % (esc(_ts(e)[:10]), esc(e.get("entity", "")),
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
                         % (kind, href, esc(name.split(".", 1)[0])))
        parts.append('</ul>')
    else:
        parts.append('<p class="muted">No reports yet.</p>')
    parts.append('</div>')
    return "".join(parts)


def report_kind(name):
    return "Weekly digest" if name.endswith(".weekly.md") else "Daily briefing"


def report_date(name):
    return name.split(".", 1)[0]


def report_title(query):
    """The <title> suffix for a /reports page (so a saved PDF gets a sensible name)."""
    if (query.get("print") or [""])[0] == "1":
        return "All reports"
    name = (query.get("f") or [""])[0]
    if name and name in list_reports():
        return "%s %s" % (report_kind(name), report_date(name))
    return "Reports"


def _report_card(name, printable=False):
    """Render one report as a card with the email-style header chrome."""
    with open(os.path.join(KB, name), encoding="utf-8") as f:
        body = render_markdown(f.read())
    cls = "card printreport" if printable else "card"
    return ('<div class="%s"><div class="brand" style="margin-bottom:4px">'
            '<span class="eyebrow">Vantage Point</span>Market intelligence</div>'
            '<p class="meta">%s &middot; %s</p>'
            '<hr style="border:0;border-top:1px solid var(--line);margin:14px 0">'
            '<div class="body">%s</div></div>'
            % (cls, esc(report_kind(name)), esc(report_date(name)), body))


def reports_inner(query):
    available = list_reports()
    if (query.get("print") or [""])[0] == "1":   # combined "all reports" -> one PDF
        parts = ['<p class="meta noprint"><a href="/reports">&larr; Back</a> &middot; '
                 'Print (Ctrl/Cmd+P) &rarr; Save as PDF.</p><h1>Reports</h1>']
        if not available:
            return "".join(parts) + '<p class="muted">No reports yet.</p>'
        parts += [_report_card(n, printable=True) for n in available]
        return "".join(parts)

    name = (query.get("f") or [""])[0]
    if name:
        if name not in available:   # guard against path traversal / stale links
            return '<div class="card"><h1>Report not found</h1>' \
                   '<p class="muted"><a href="/reports">Back to reports</a></p></div>'
        return ('<p class="meta noprint"><a href="/reports">&larr; All reports</a> '
                '&middot; <span class="muted">Print (Ctrl/Cmd+P) &rarr; Save as PDF</span></p>'
                + _report_card(name))

    parts = ['<h1>Reports</h1><p class="meta">The same briefings that go out by email, '
             'rendered here. <a class="noprint" href="/reports?print=1">Save all as PDF</a>.'
             '</p><div class="card">']
    if available:
        parts.append('<ul class="reportlist">')
        for n in available[:MAX_REPORTS]:
            kind = "weekly" if n.endswith(".weekly.md") else "daily"
            parts.append('<li><span class="tag">%s</span><a href="/reports?f=%s">%s</a></li>'
                         % (kind, esc(n), esc(report_date(n))))
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

    # Missed signals: the recall half of calibration. Thumbs grade only what WAS
    # surfaced; this box records what should have been but never appeared.
    parts.append('<div class="card"><h2>Report a missed signal</h2>'
                 '<p class="sublabel">Saw something relevant the monitor never '
                 'surfaced? Paste its URL &mdash; it becomes a false-negative '
                 'example for the next runs and the next profile refresh.</p>'
                 '<form class="missed" method="get" action="/missed">'
                 '<input type="url" name="url" required '
                 'placeholder="https://&hellip; (the item it missed)">'
                 '<input type="text" name="note" '
                 'placeholder="why it mattered (optional)">'
                 '<button type="submit">Report</button></form>')
    missed = recent_missed()
    if missed:
        parts.append('<ul class="events">')
        for r in missed:
            link = safe_url(r.get("url"))
            shown = ('<a href="%s" target="_blank" rel="noopener noreferrer">%s</a>'
                     % (esc(link), esc(link))) if link else esc(r.get("url", ""))
            note = r.get("note")
            note = " &mdash; %s" % esc(note) if isinstance(note, str) and note else ""
            parts.append('<li class="muted">%s | missed: %s%s</li>'
                         % (esc(_ts(r)[:10]), shown, note))
        parts.append('</ul>')
    parts.append('</div>')

    parts.append('<div class="card">')
    if not items:
        parts.append('<p class="muted">No surfaced items yet.</p>')
    for idx, it in enumerate(items):
        rid = esc(it.get("id"))
        v = verdicts.get(it.get("id"))
        up = " on" if v == "up" else ""
        down = " on" if v == "down" else ""
        # Anchor each item so a grade can redirect back to it (keeping the page
        # scrolled to the graded row) instead of jumping to the top. The index is
        # stable: recent_items() reads only seen.jsonl, which grading never touches.
        parts.append('<div class="item" id="item-%d"><div class="sig">%s &middot; score %s</div>'
                     % (idx, esc(it.get("signal", "?")), esc(it.get("score", "?"))))
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


def entity_href(name):
    return "/entity?e=" + quote(str(name), safe="")


def entities_inner():
    rows = all_entities()
    parts = ['<h1>Entities</h1>',
             '<p class="meta">A dossier per tracked entity, accumulated across runs '
             '&mdash; metrics, events, and the items surfaced about it.</p>',
             '<div class="card">']
    if rows:
        parts.append('<table><tr><th>Entity</th><th>Items</th><th>Observations</th>'
                     '<th>Last activity</th></tr>')
        for r in rows:
            last = esc(r["last"]) if r["last"] else "&mdash;"
            parts.append('<tr><td><a href="%s">%s</a></td><td class="num">%d</td>'
                         '<td class="num">%d</td><td class="muted">%s</td></tr>'
                         % (esc(entity_href(r["name"])), esc(r["name"]),
                            r["items"], r["observations"], last))
        parts.append('</table>')
    else:
        parts.append('<p class="muted">No entities yet &mdash; they accumulate as the '
                     'monitor records observations and tags surfaced items.</p>')
    parts.append('</div>')
    return "".join(parts)


def entity_inner(query):
    name = (query.get("e") or [""])[0]
    known = {r["name"] for r in all_entities()}
    if name not in known:
        return ('<div class="card"><h1>Entity not found</h1>'
                '<p class="muted"><a href="/entities">Back to entities</a></p></div>')
    parts = ['<p class="meta noprint"><a href="/entities">&larr; All entities</a></p>',
             '<h1>%s</h1>' % esc(name),
             '<p class="meta">Everything on file for this entity, oldest state to '
             'newest report.</p>']

    metrics = [r for r in tracked_entities() if r["entity"] == name]
    if metrics:
        parts.append('<div class="card"><h2>Metrics</h2>'
                     '<table><tr><th>Metric</th><th>Latest</th><th>Recent</th>'
                     '<th>As of</th></tr>')
        for r in metrics:
            parts.append('<tr><td>%s</td><td class="num">%s %s</td>'
                         '<td class="spark">%s</td><td class="muted">%s</td></tr>'
                         % (esc(r["metric"]), esc(r["latest"]), esc(r["unit"]),
                            spark(r["series"]), esc(r["as_of"])))
        parts.append('</table></div>')

    expectations = entity_expectations(name)
    if expectations:
        parts.append('<div class="card"><h2>Expected</h2>'
                     '<p class="sublabel">Forward-dated expectations on file for this '
                     'entity &mdash; pending first, then the met/lapsed history.</p>'
                     '<table><tr><th>Due</th><th>Event</th><th>Status</th></tr>')
        for e in expectations:
            event = esc(e["event"])
            if e["due_text"]:
                event += ' <span class="muted">(&ldquo;%s&rdquo;)</span>' % esc(e["due_text"])
            if e["source"]:
                event += (' &middot; <a href="%s" target="_blank" '
                          'rel="noopener noreferrer">source</a>' % esc(e["source"]))
            if e["note"]:
                event += '<div class="muted">%s</div>' % esc(e["note"])
            parts.append('<tr><td class="num">%s</td><td>%s</td>'
                         '<td class="%s">%s</td></tr>'
                         % (esc(e["due"]) or "&mdash;", event, e["cls"], esc(e["badge"])))
        parts.append('</table></div>')

    events = entity_events(name)
    if events:
        parts.append('<div class="card"><h2>Event timeline</h2>')
        # The Cadence line (quiet detection): the entity's normal rhythm vs its current
        # silence, from the same bin/cadence.py arithmetic the monitor flags with. The
        # warning glyph (U+26A0) is built from its code point so this file stays ASCII.
        for c in entity_cadence(name):
            line = ('Cadence: ~%s-day %s rhythm (%d on record) &middot; last %s'
                    % (esc(c["median_gap_days"]), esc(c["event_type"]),
                       c["n_events"], esc(c["last_seen"])))
            if c["quiet"]:
                line += (' &middot; <span class="st-bad">%dd quiet %s</span>'
                         % (c["silence_days"], chr(0x26A0)))
            parts.append('<p class="sublabel">%s</p>' % line)
        parts.append('<ul class="events">')
        for e in events:
            note = e.get("note")
            if not note:
                v = e.get("value")
                note = v if isinstance(v, str) else ""
            parts.append('<li class="muted">%s | %s: %s</li>'
                         % (esc(_ts(e)[:10]), esc(e.get("event_type", "event")), esc(note)))
        parts.append('</ul></div>')

    items = entity_items(name)
    parts.append('<div class="card"><h2>Surfaced items</h2>')
    if items:
        verdicts = latest_verdicts()
        for it in items:
            parts.append('<div class="item"><div class="sig">%s &middot; %s &middot; '
                         'score %s</div>'
                         % (esc(it.get("date", "")), esc(it.get("signal", "?")),
                            esc(it.get("score", "?"))))
            parts.append('<div><strong>%s</strong></div>' % esc(it.get("title", "")))
            if it.get("so_what"):
                parts.append('<div class="muted">%s</div>' % esc(it["so_what"]))
            link = safe_url(it.get("url"))
            tail = []
            if link:
                tail.append('<a href="%s" target="_blank" rel="noopener noreferrer">'
                            'source</a>' % esc(link))
            v = verdicts.get(it.get("id"))
            if v:
                tail.append('<span class="verdict">graded: %s</span>' % esc(v))
            if tail:
                parts.append('<div class="grade">%s</div>' % " ".join(tail))
            parts.append('</div>')
    else:
        parts.append('<p class="muted">No surfaced items mention this entity yet.</p>')
    parts.append('</div>')
    return "".join(parts)


def draft_diff():
    """Unified diff of the pending draft vs the approved profile, computed live
    (stdlib difflib) so it can never go stale. Empty when either file is missing
    or they match -- a first bootstrap has nothing to diff against."""
    try:
        with open(PROFILE, encoding="utf-8") as f:
            a = f.read().splitlines()
        with open(PROFILE_DRAFT, encoding="utf-8") as f:
            b = f.read().splitlines()
    except OSError:
        return ""
    return "\n".join(difflib.unified_diff(
        a, b, fromfile="profile.yaml", tofile="profile.draft.yaml", lineterm=""))


def render_diff(text):
    """Read-only diff rendering: escape everything, then tint +/- lines."""
    lines = []
    for raw in text.split("\n"):
        line = esc(raw)
        if raw.startswith("+") and not raw.startswith("+++"):
            lines.append('<span class="da">%s</span>' % line)
        elif raw.startswith("-") and not raw.startswith("---"):
            lines.append('<span class="dr">%s</span>' % line)
        elif raw.startswith("@@"):
            lines.append('<span class="c">%s</span>' % line)
        else:
            lines.append(line)
    return '<pre class="yaml">%s</pre>' % "\n".join(lines)


def draft_diff_card():
    """The 'what changed' card on the draft view -- the refresh review surface:
    skim what your grades re-ranked instead of re-reading the whole profile."""
    d = draft_diff()
    if not d:
        return ""
    return ('<div class="card"><h2>What changed vs the approved profile</h2>'
            '<p class="sublabel">Computed live from <code>profile.yaml</code> vs '
            '<code>profile.draft.yaml</code>. Review it, edit the draft if needed, '
            'then approve with <code>cp profile.draft.yaml profile.yaml</code>.</p>'
            '%s</div>' % render_diff(d))


def backtest_card():
    """The 'what effect' card on the draft view: how the draft rubric scores the items
    you already graded (agreement vs your verdicts, the regression list). Unlike the
    diff (recomputed live via difflib), this is a point-in-time artifact of the scoring
    pass -- show its file mtime so staleness is visible if the draft was hand-edited
    afterwards. Absent until a refresh runs the backtest."""
    if not os.path.exists(PROFILE_DRAFT_BACKTEST):
        return ""
    try:
        with open(PROFILE_DRAFT_BACKTEST, encoding="utf-8") as f:
            body = render_markdown(f.read())
        when = datetime.fromtimestamp(
            os.path.getmtime(PROFILE_DRAFT_BACKTEST)).strftime("%Y-%m-%d")
    except OSError:
        return ""
    return ('<div class="card"><p class="sublabel">Point-in-time replay of your graded '
            'items under the draft rubric &mdash; backtested %s. Recomputed only when a '
            'refresh runs; edit the draft by hand and this can go stale.</p>'
            '<div class="body">%s</div></div>' % (esc(when), body))


def _draft_aid_card(path, sublabel):
    """Render a deep-research review-aid markdown (the feed check or the challenge
    report) as a draft-view card, stamped with its file mtime so a stale artifact is
    visible. Absent until that pass runs; empty string when missing/unreadable."""
    if not os.path.exists(path):
        return ""
    try:
        with open(path, encoding="utf-8") as f:
            body = render_markdown(f.read())
        when = datetime.fromtimestamp(os.path.getmtime(path)).strftime("%Y-%m-%d")
    except OSError:
        return ""
    return ('<div class="card"><p class="sublabel">%s &mdash; %s.</p>'
            '<div class="body">%s</div></div>' % (sublabel, esc(when), body))


def feedcheck_card():
    """Deterministic verification that the draft's RSS/Atom feeds actually serve a feed
    (bootstrap's fetch.py --verify) -- a bad feed caught at the gate, not weeks later."""
    return _draft_aid_card(
        PROFILE_DRAFT_FEEDCHECK,
        "Deterministic check of the draft's feeds (fetch.py --verify); run")


def challenge_card():
    """The adversarial challenge of the draft's weakest claims (models.challenge): what
    an attacker with fresh web evidence could confirm, correct, or not verify."""
    return _draft_aid_card(
        PROFILE_DRAFT_CHALLENGE,
        "Adversarial challenge of the draft's claims (models.challenge); run")


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


def summary_card(summary_path, subtitle):
    """Render a profile summary markdown the same way the bootstrap review email does:
    the Vantage Point header chrome (subject name + subtitle) over the rendered body."""
    with open(summary_path, encoding="utf-8") as f:
        body = render_markdown(f.read())
    title = cfg_get_text("subject", "name") or "Market intelligence"
    return ('<div class="card"><div class="brand" style="margin-bottom:4px">'
            '<span class="eyebrow">Vantage Point</span>%s</div>'
            '<p class="meta">%s</p>'
            '<hr style="border:0;border-top:1px solid var(--line);margin:14px 0">'
            '<div class="body">%s</div></div>' % (esc(title), esc(subtitle), body))


def _summary_is_current(summary_path, yaml_path):
    """Only prefer the digest when it's at least as fresh as the YAML it summarizes:
    approving a new profile.yaml without refreshing profile.summary.md must not leave the
    portal showing a stale digest (the monitor scores against the YAML, not the digest)."""
    try:
        if not os.path.exists(yaml_path):
            return True
        return os.path.getmtime(summary_path) >= os.path.getmtime(yaml_path)
    except OSError:
        return False


def profile_inner(query):
    draft = (query.get("draft") or [""])[0] == "1"
    raw = (query.get("raw") or [""])[0] == "1"
    banner = ""
    if os.path.exists(PROFILE_DRAFT) and not draft:
        banner = ('<div class="banner">A <strong>profile.draft.yaml</strong> is awaiting '
                  'review. <a href="/profile?draft=1">View the draft and what changed</a> '
                  '&mdash; promote it with <code>cp profile.draft.yaml profile.yaml</code>.'
                  '</div>')
    if draft:
        yaml_path, summary_path = PROFILE_DRAFT, PROFILE_DRAFT_SUMMARY
        title, subtitle = "Profile draft", "Profile draft - for review"
        intro = ('The bootstrap\'s proposed profile, not yet approved. '
                 '<a href="/profile">View the approved profile</a>.')
        missing = "No profile.draft.yaml present."
        # On a refresh, lead the review with the diff against the approved profile,
        # then the backtest -- what changed, then what effect it has -- then the
        # deep-research review aids (deterministic feed check, adversarial challenge).
        banner += draft_diff_card()
        banner += backtest_card()
        banner += feedcheck_card()
        banner += challenge_card()
    else:
        yaml_path, summary_path = PROFILE, PROFILE_SUMMARY
        title, subtitle = "Profile", "Approved profile"
        intro = "The approved profile the monitor scores against (read-only)."
        missing = "No profile.yaml yet &mdash; run bootstrap, then promote the draft."

    has_summary = os.path.exists(summary_path)
    current = has_summary and _summary_is_current(summary_path, yaml_path)

    # Prefer the human-readable summary (rendered like the bootstrap email) when it's
    # current; keep the YAML one click away as the source of truth (?raw=1).
    if current and not raw:
        raw_link = "/profile?raw=1" + ("&draft=1" if draft else "")
        parts = ["<h1>%s</h1>" % esc(title), '<p class="meta">%s</p>' % intro]
        if banner:
            parts.append(banner)
        parts.append(summary_card(summary_path, subtitle))
        parts.append('<p class="note">Human-readable digest. '
                     '<a href="%s">View the raw %s</a>.</p>'
                     % (raw_link, esc(os.path.basename(yaml_path))))
        return "".join(parts)

    if has_summary and not current:    # a stale digest exists: show the YAML, flag it
        intro += (' <em>A <code>%s</code> exists but predates this profile &mdash; '
                  'regenerate it to show the formatted summary.</em>'
                  % esc(os.path.basename(summary_path)))
    elif current:                      # current digest, but ?raw=1 was requested
        intro += (' <a href="/profile%s">View the formatted summary</a>.'
                  % ("?draft=1" if draft else ""))
    return file_view_inner(title, yaml_path, intro, missing, banner)


def config_inner():
    return file_view_inner(
        "Configuration", CONFIG,
        "The live monitor configuration (read-only). Edit the file on disk to change it.",
        "No monitor-config.yaml found &mdash; copy monitor-config.example.yaml to start.")


# ----------------------------------------------------------------------------- server

# Defense-in-depth for the report views: reports are agent-written from web sweeps, so
# even with raw HTML disabled in the renderers, this CSP blocks script execution, inline
# event handlers, and javascript: navigation if anything slips through. We use an inline
# <style> block and inline style attributes, so style-src must allow 'unsafe-inline';
# everything else (scripts, objects, frames) defaults to 'none'.
CSP = "default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'"


class Handler(BaseHTTPRequestHandler):
    def _security_headers(self):
        self.send_header("Content-Security-Policy", CSP)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")

    def _send(self, code, body, ctype="text/html; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self._security_headers()
        self.end_headers()
        self.wfile.write(body)

    def _redirect(self, location):
        self.send_response(303)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self._security_headers()
        self.end_headers()

    def do_GET(self):  # noqa: N802
        u = urlparse(self.path)
        q = parse_qs(u.query)
        path = u.path
        if path in ("/", "/index.html"):
            self._send(200, shell("/", overview_inner()))
        elif path == "/reports":
            self._send(200, shell("/reports", reports_inner(q), title=report_title(q)))
        elif path == "/entities":
            self._send(200, shell("/entities", entities_inner(), title="Entities"))
        elif path == "/entity":
            name = (q.get("e") or [""])[0]
            self._send(200, shell("/entities", entity_inner(q), title=name or "Entity"))
        elif path == "/review":
            self._send(200, shell("/review", review_inner(), title="Review"))
        elif path == "/profile":
            draft = (q.get("draft") or [""])[0] == "1"
            self._send(200, shell("/profile", profile_inner(q),
                                  title="Profile draft" if draft else "Profile"))
        elif path == "/config":
            self._send(200, shell("/config", config_inner(), title="Configuration"))
        elif path == "/grade":
            rid = (q.get("id") or [""])[0]
            verdict = (q.get("v") or [""])[0]
            items = recent_items()
            idx = next((i for i, it in enumerate(items)
                        if str(it.get("id")) == rid), None)
            item = items[idx] if idx is not None else None
            if item and verdict in ("up", "down"):
                record_grade(item, verdict)
                # Land back on the graded row, not the top of the page.
                self._redirect("/review#item-%d" % idx)
            else:
                self._send(400, b"bad grade request")
        elif path == "/missed":
            url_v = (q.get("url") or [""])[0].strip()
            note = (q.get("note") or [""])[0].strip()
            if safe_url(url_v):
                record_missed(url_v, note)
                self._redirect("/review")
            else:
                self._send(400, b"bad missed-signal request: url must be http(s)")
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
