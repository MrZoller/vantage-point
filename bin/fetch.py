#!/usr/bin/env python3
"""fetch.py -- deterministic feed sweep, run by bin/monitor.sh before the agent.

Usage: fetch.py [--hours N] [--max N] [--seen FILE] [--out FILE] [--health FILE]
                [YAML_FILES...]
       fetch.py --verify [--out FILE] DRAFT.yaml   (refresh-gate feed verification)

Scans the given YAML files (the approved profile and the config) for `feeds:` lists
of RSS/Atom URLs, pulls each feed, keeps entries that are inside the lookback window
and not already in the seen file, and writes them as candidate JSONL (newest first,
capped at --max) for the monitor to score. This turns the sweep of those sources
into a deterministic, auditable fact -- the LLM stops being a crawler there and
spends its browsing budget only on sources without a feed.

With --health, per-feed sweep health is persisted to a JSON file (last success,
consecutive failures, newest entry seen) so a feed that 404s for weeks or stops
publishing is visible (the portal's Feed health card) instead of silent recall rot.

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
from urllib.parse import urljoin, urlparse

FEED_ITEM_RE = re.compile(r"^(\s*)-\s*['\"]?(https?://\S+?)['\"]?\s*(?:#.*)?$")
FEEDS_KEY_RE = re.compile(r"^(\s*)feeds:\s*(\[[^\]]*\])?\s*(?:#.*)?$")


def _inline_urls(bracketed):
    """URLs from an inline YAML list body like '[a, "b"]' (brackets included)."""
    urls = []
    for part in bracketed[1:-1].split(","):
        part = part.strip().strip("'\"")
        if part.startswith(("http://", "https://")):
            urls.append(part)
    return urls


def feeds_from(path):
    """All URLs under any `feeds:` list in a YAML file, scanned without a YAML
    library (per the repo convention). Handles both block lists (`- url` lines)
    and inline lists (`feeds: [url, url]`) -- a one-line config must not silently
    lose the deterministic sweep. A missing file reads as none."""
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
            inline = m.group(2)
            if inline is not None:              # `feeds: [...]` (possibly empty)
                urls.extend(_inline_urls(inline))
                in_feeds = False
            else:                               # bare `feeds:` -> a block list follows
                in_feeds = True
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


def _rss_link(el):
    """An RSS item's URL: <link>, else a permalink <guid> (the RSS default unless
    isPermaLink="false") -- feeds that only set a guid still yield candidates."""
    link = _child_text(el, {"link"})
    if link:
        return link
    for child in el:
        if _local(child.tag) == "guid" \
                and (child.get("isPermaLink") or "true").lower() != "false":
            return (child.text or "").strip()
    return ""


def _parse_when(text):
    """RFC 822 (RSS) or ISO 8601 (Atom) -> aware UTC datetime, else None.

    Normalized to UTC here so the formatted `published` string (and therefore the
    newest-first sort and the --max cap) is correct across feeds in different
    timezones -- an offset timestamp formatted as wall-clock-with-Z would sort a
    newer item behind older ones."""
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
    return dt.astimezone(timezone.utc)


class _RedirectHandler(urllib.request.HTTPRedirectHandler):
    """Follow 308 Permanent Redirect, which urllib only learned to handle in 3.11.

    monitor.sh appends to launchd's minimal PATH (so a caller's stubs still win), which
    resolves python3 to the macOS system 3.9; bootstrap.sh prepends and gets a newer one.
    Without this, a feed that answers 308 verifies clean at bootstrap and then fails every
    monitor run -- the split that hid a dead VentureBeat feed for 68 runs. Mirrors CPython
    3.11+, which aliases 308 onto the 302 handler."""

    http_error_308 = urllib.request.HTTPRedirectHandler.http_error_302

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # 3.9's redirect_request rejects any code outside (301, 302, 303, 307)
        # before the handler above ever gets to follow it. 307 carries the same
        # method-preserving semantics as 308, so present it as that.
        if code == 308:
            code = 307
        return super().redirect_request(req, fp, code, msg, headers, newurl)


_OPENER = urllib.request.build_opener(_RedirectHandler)


def fetch_feed(feed, timeout=20):
    """Pull a feed's bytes. Returns (data, None) on success or (None, error_string)
    on any network/OS error -- the single fetch path shared by the sweep and --verify
    so they behave identically on a down or slow feed (and across python versions)."""
    req = urllib.request.Request(feed, headers={"User-Agent": "vantage-point-fetch"})
    try:
        with _OPENER.open(req, timeout=timeout) as resp:
            return resp.read(), None
    except (urllib.error.URLError, OSError) as exc:
        return None, str(exc)


def parse_entries(data):
    """[(title, link, when)] from RSS 2.0/RDF or Atom bytes; None if it isn't a feed.

    A document that parses as XML but whose root isn't a feed root (rss/rdf/feed) --
    e.g. a sitemap's <urlset> or an HTML-ish page -- returns None, not an empty list,
    so --verify flags it for removal and feed health counts it a failure instead of
    silently blessing a non-feed URL as a working (0-entry) feed."""
    try:
        root = ET.fromstring(data)
    except ET.ParseError:
        return None
    root_tag = _local(root.tag)
    if root_tag not in ("feed", "rss", "rdf"):
        return None
    entries = []
    if root_tag == "feed":                               # Atom
        for el in root:
            if _local(el.tag) != "entry":
                continue
            entries.append((_child_text(el, {"title"}), _atom_link(el),
                            _parse_when(_child_text(el, {"published", "updated"}))))
    else:                                                # RSS 2.0 / RDF
        for el in root.iter():
            if _local(el.tag) != "item":
                continue
            entries.append((_child_text(el, {"title"}), _rss_link(el),
                            _parse_when(_child_text(el, {"pubdate", "date"}))))
    return entries


FAIL_WARN_AFTER = 3   # consecutive failed runs before a feed is called out loudly


def load_health(path):
    """The persisted per-feed health map; anything unreadable reads as empty."""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def update_health(path, outcomes):
    """Persist per-feed sweep health. `outcomes`: feed -> (ok, detail), where detail
    is the newest entry timestamp on success ("" if none parsed) or the error string
    on failure. Carries forward the previous run's counters, drops feeds no longer
    configured, and warns about a feed that has failed FAIL_WARN_AFTER runs in a row.
    Best-effort by contract: a problem here is a warning, never a failed sweep."""
    prev = load_health(path)
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    health = {}
    for feed, (ok, detail) in outcomes.items():
        rec = prev.get(feed)
        rec = rec if isinstance(rec, dict) else {}
        prev_entry = rec.get("last_entry")
        prev_entry = prev_entry if isinstance(prev_entry, str) else ""
        if ok:
            health[feed] = {
                "last_ok": now,
                "consecutive_failures": 0,
                # Newest entry EVER seen on this feed (any date, in-window or not):
                # a 200-OK feed that stopped publishing is stale, not healthy.
                "last_entry": max(prev_entry, detail),
            }
        else:
            fails = rec.get("consecutive_failures")
            fails = (fails if isinstance(fails, int) and fails >= 0 else 0) + 1
            last_ok = rec.get("last_ok")
            health[feed] = {
                "last_ok": last_ok if isinstance(last_ok, str) else "",
                "consecutive_failures": fails,
                "last_entry": prev_entry,
                "last_error": now,
                "error": detail,
            }
            if fails >= FAIL_WARN_AFTER:
                print("[fetch] WARNING: %s has failed %d runs in a row - the sweep "
                      "no longer covers it (fix or remove the feed)" % (feed, fails),
                      file=sys.stderr)
    try:
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(health, f, ensure_ascii=False, indent=1, sort_keys=True)
            f.write("\n")
        os.replace(tmp, path)
    except OSError as exc:
        print("[fetch] WARNING: could not write feed health to %s: %s" % (path, exc),
              file=sys.stderr)


def _parse_args(argv):
    hours, cap, seen, out, health, verify = 30, 200, "", "", "", False
    files = []
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in ("--hours", "--max", "--seen", "--out", "--health"):
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
            elif arg == "--out":
                out = val
            else:
                health = val
        elif arg == "--verify":
            verify = True
        elif arg in ("-h", "--help"):
            return None
        else:
            files.append(arg)
        i += 1
    return hours, cap, seen, out, health, verify, files


def verify_feeds(files, out_path):
    """At the refresh gate, fetch every `feeds:` URL in the DRAFT and report per feed
    whether it actually serves a parseable RSS/Atom feed -- turning the bootstrap
    prompt's 'verify each URL' INSTRUCTION into a checked fact before a human approves.
    Writes a Markdown report (failures first) to out_path (or stdout). Always exits 0:
    verification is a review aid, not a gate."""
    feeds = []
    for path in files:
        for url in feeds_from(path):
            if url not in feeds:
                feeds.append(url)
    if not feeds:
        print("[fetch] no feeds in the draft - nothing to verify", file=sys.stderr)
        return 0

    good, bad = [], []
    for feed in feeds:
        data, err = fetch_feed(feed)
        if err is not None:
            bad.append((feed, err))
            continue
        entries = parse_entries(data)
        if entries is None:
            bad.append((feed, "not parseable RSS/Atom"))
            continue
        kind = "Atom" if data.lstrip()[:2048].find(b"http://www.w3.org/2005/Atom") >= 0 else "RSS"
        newest = max((w for _, _, w in entries if w is not None), default=None)
        good.append((feed, kind, len(entries),
                     newest.strftime("%Y-%m-%d") if newest else "no dated entries"))

    lines = ["## Draft feed check", ""]
    if bad:
        lines.append("**%d of %d draft feed(s) don't serve a parseable feed - fix or "
                     "remove before approving:**" % (len(bad), len(feeds)))
        for feed, why in bad:
            lines.append("- %s  (%s)" % (feed, why))
        lines.append("")
    if good:
        lines.append("Working feed(s) (%d of %d):" % (len(good), len(feeds)))
        for feed, kind, n, newest in good:
            lines.append("- %s  (%s, %d entries, newest %s)" % (feed, kind, n, newest))
    if not bad:
        lines.append("")
        lines.append("All %d draft feed(s) serve a parseable feed." % len(feeds))

    report = "\n".join(lines) + "\n"
    if out_path:
        tmp = out_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(report)
        os.replace(tmp, out_path)
    else:
        sys.stdout.write(report)
    print("[fetch] feed check: %d of %d draft feed(s) failed" % (len(bad), len(feeds)),
          file=sys.stderr)
    return 0


def main():
    try:
        parsed = _parse_args(sys.argv[1:])
    except ValueError:
        parsed = None
    if parsed is None:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    hours, cap, seen_path, out_path, health_path, verify, files = parsed

    if verify:
        return verify_feeds(files, out_path)

    feeds = []
    for path in files:
        for url in feeds_from(path):
            if url not in feeds:
                feeds.append(url)
    if not feeds:
        if health_path:          # nothing configured -> nothing to report health on
            update_health(health_path, {})
        print("[fetch] no feeds configured - skipping the deterministic sweep",
              file=sys.stderr)
        return 0

    seen = seen_urls(seen_path) if seen_path else set()
    cutoff = datetime.now(timezone.utc) - timedelta(hours=hours)
    candidates, urls_emitted, failed, outcomes = [], set(), 0, {}
    for feed in feeds:
        data, err = fetch_feed(feed)
        if err is not None:
            failed += 1
            outcomes[feed] = (False, err)
            print("[fetch] WARNING: %s failed: %s" % (feed, err), file=sys.stderr)
            continue
        entries = parse_entries(data)
        if entries is None:
            failed += 1
            outcomes[feed] = (False, "not parseable RSS/Atom")
            print("[fetch] WARNING: %s is not parseable RSS/Atom" % feed, file=sys.stderr)
            continue
        newest = max((w for _, _, w in entries if w is not None), default=None)
        outcomes[feed] = (True, newest.strftime("%Y-%m-%dT%H:%M:%SZ") if newest else "")
        for title, link, when in entries:
            if not title or not link:
                continue
            # Resolve a relative entry link (e.g. "/posts/123") against the feed URL
            # BEFORE dedup, so the stored url is fetchable and matches the absolute
            # urls already in the seen file. Absolute links pass through unchanged.
            link = urljoin(feed, link)
            if link in seen or link in urls_emitted:
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
    if health_path:
        update_health(health_path, outcomes)
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
