#!/usr/bin/env python3
"""fetch.py -- deterministic feed sweep, run by bin/monitor.sh before the agent.

Usage: fetch.py [--hours N] [--max N] [--seen FILE] [--out FILE] [YAML_FILES...]

Scans the given YAML files (the approved profile and the config) for `feeds:` lists
of RSS/Atom URLs, pulls each feed, keeps entries that are inside the lookback window
and not already in the seen file, and writes them as candidate JSONL (newest first,
capped at --max) for the monitor to score. This turns the sweep of those sources
into a deterministic, auditable fact -- the LLM stops being a crawler there and
spends its browsing budget only on sources without a feed.

Fail-safe by contract: a feed that is down or unparseable is a warning on stderr,
never a failure -- the agentic sweep is the backstop. Exits 0 unless the arguments
themselves are unusable. Stdlib only; http(s) feeds only.

Candidate record: {"title", "url", "published", "source", "feed"}.
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from urllib.parse import urlparse

FEED_ITEM_RE = re.compile(r"^(\s*)-\s*['\"]?(https?://\S+?)['\"]?\s*(?:#.*)?$")
FEEDS_KEY_RE = re.compile(r"^(\s*)feeds:\s*(\[\s*\])?\s*(?:#.*)?$")


def feeds_from(path):
    """All URLs under any `feeds:` list in a YAML file, scanned without a YAML
    library (per the repo convention). `feeds: []` and a missing file read as none."""
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        return []
    urls, in_feeds, key_indent = [], False, 0
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        m = FEEDS_KEY_RE.match(line)
        if m:
            in_feeds = m.group(2) is None       # `feeds: []` has nothing to collect
            key_indent = len(m.group(1))
            continue
        if in_feeds:
            fm = FEED_ITEM_RE.match(line)
            # YAML allows list items at the key's own indent or deeper.
            if fm and len(fm.group(1)) >= key_indent:
                urls.append(fm.group(2))
                continue
            in_feeds = False
    return urls


def seen_urls(path):
    out = set()
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(rec, dict) and isinstance(rec.get("url"), str):
                    out.add(rec["url"])
    except OSError:
        pass
    return out


def _local(tag):
    """Element tag without its XML namespace, lowercased."""
    return str(tag).rsplit("}", 1)[-1].lower()


def _child_text(el, names):
    for child in el:
        if _local(child.tag) in names and (child.text or "").strip():
            return child.text.strip()
    return ""


def _atom_link(el):
    fallback = ""
    for child in el:
        if _local(child.tag) != "link":
            continue
        href = (child.get("href") or "").strip()
        if not href:
            continue
        if (child.get("rel") or "alternate") == "alternate":
            return href
        if not fallback:
            fallback = href
    return fallback


def _parse_when(text):
    """RFC 822 (RSS) or ISO 8601 (Atom) -> aware datetime, else None."""
    if not text:
        return None
    try:
        dt = parsedate_to_datetime(text)
    except (TypeError, ValueError):
        try:
            dt = datetime.fromisoformat(text.replace("Z", "+00:00"))
        except ValueError:
            return None
    if dt is None:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def parse_entries(data):
    """[(title, link, when)] from RSS 2.0/RDF or Atom bytes; None if unparseable."""
    try:
        root = ET.fromstring(data)
    except ET.ParseError:
        return None
    entries = []
    if _local(root.tag) == "feed":                       # Atom
        for el in root:
            if _local(el.tag) != "entry":
                continue
            entries.append((_child_text(el, {"title"}), _atom_link(el),
                            _parse_when(_child_text(el, {"published", "updated"}))))
    else:                                                # RSS 2.0 / RDF
        for el in root.iter():
            if _local(el.tag) != "item":
                continue
            entries.append((_child_text(el, {"title"}), _child_text(el, {"link"}),
                            _parse_when(_child_text(el, {"pubdate", "date"}))))
    return entries


def _parse_args(argv):
    hours, cap, seen, out = 30, 200, "", ""
    files = []
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in ("--hours", "--max", "--seen", "--out"):
            i += 1
            if i >= len(argv):
                return None
            val = argv[i]
            if arg == "--hours":
                hours = int(val)
            elif arg == "--max":
                cap = int(val)
            elif arg == "--seen":
                seen = val
            else:
                out = val
        elif arg in ("-h", "--help"):
            return None
        else:
            files.append(arg)
        i += 1
    return hours, cap, seen, out, files


def main():
    try:
        parsed = _parse_args(sys.argv[1:])
    except ValueError:
        parsed = None
    if parsed is None:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    hours, cap, seen_path, out_path, files = parsed

    feeds = []
    for path in files:
        for url in feeds_from(path):
            if url not in feeds:
                feeds.append(url)
    if not feeds:
        print("[fetch] no feeds configured - skipping the deterministic sweep",
              file=sys.stderr)
        return 0

    seen = seen_urls(seen_path) if seen_path else set()
    cutoff = datetime.now(timezone.utc) - timedelta(hours=hours)
    candidates, urls_emitted, failed = [], set(), 0
    for feed in feeds:
        req = urllib.request.Request(feed, headers={"User-Agent": "vantage-point-fetch"})
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                data = resp.read()
        except (urllib.error.URLError, OSError) as exc:
            failed += 1
            print("[fetch] WARNING: %s failed: %s" % (feed, exc), file=sys.stderr)
            continue
        entries = parse_entries(data)
        if entries is None:
            failed += 1
            print("[fetch] WARNING: %s is not parseable RSS/Atom" % feed, file=sys.stderr)
            continue
        for title, link, when in entries:
            if not title or not link or link in seen or link in urls_emitted:
                continue
            if when is not None and when < cutoff:
                continue
            urls_emitted.add(link)
            candidates.append({
                "title": title, "url": link,
                # Entries with no parseable date are kept (can't be proven stale);
                # the empty string sorts them after dated ones below.
                "published": when.strftime("%Y-%m-%dT%H:%M:%SZ") if when else "",
                "source": urlparse(link).netloc or urlparse(feed).netloc,
                "feed": feed,
            })
    candidates.sort(key=lambda c: c["published"], reverse=True)
    if cap > 0:
        candidates = candidates[:cap]

    body = "".join(json.dumps(c, ensure_ascii=False) + "\n" for c in candidates)
    if out_path:
        if candidates:                       # no candidates -> no file (callers test -s)
            tmp = out_path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(body)
            os.replace(tmp, out_path)
    else:
        sys.stdout.write(body)
    print("[fetch] %d candidate(s) from %d feed(s)%s"
          % (len(candidates), len(feeds),
             " (%d feed(s) failed)" % failed if failed else ""), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
