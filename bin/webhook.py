#!/usr/bin/env python3
"""webhook.py <url> <heading> <mode> <date> -- POST a report (Markdown on stdin) to
a webhook as JSON.

One generic payload covers the common receivers at once -- each reads the key it
knows and ignores the rest:

  text             heading + the full Markdown (Slack incoming webhooks render this)
  content          the same, truncated to Discord's 2000-char message limit
  title/mode/date  metadata for generic receivers
  report_markdown  the untruncated report body alone

Exits 0 on a 2xx response, nonzero otherwise. The caller (bin/monitor.sh) treats
webhook delivery as optional and fail-safe: the report is already on disk, so a
failed post warns and never fails the run. Stdlib only.
"""
import json
import sys
import urllib.error
import urllib.request

DISCORD_LIMIT = 2000


class RefuseRedirects(urllib.request.HTTPRedirectHandler):
    """Leave redirect responses as HTTP errors instead of changing the request."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def build_payload(heading, mode, date, body):
    text = "%s\n\n%s" % (heading, body) if heading else body
    if len(text) > DISCORD_LIMIT:
        content = text[: DISCORD_LIMIT - 18].rstrip() + "\n... (truncated)"
    else:
        content = text
    return {"title": heading, "mode": mode, "date": date,
            "text": text, "content": content, "report_markdown": body}


def main():
    if len(sys.argv) != 5:
        print("usage: webhook.py URL HEADING MODE DATE  (report Markdown on stdin)",
              file=sys.stderr)
        return 2
    url, heading, mode, date = sys.argv[1:5]
    if not url.lower().startswith(("http://", "https://")):
        print("[webhook] unsupported url scheme: %s" % url, file=sys.stderr)
        return 2
    payload = json.dumps(build_payload(heading, mode, date, sys.stdin.read()),
                         ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(url, data=payload,
                                 headers={"Content-Type": "application/json",
                                          "User-Agent": "vantage-point"})
    opener = urllib.request.build_opener(RefuseRedirects())
    try:
        # opener.open raises HTTPError (a URLError) for any non-2xx status, so
        # reaching the body of the `with` means this exact URL accepted the post.
        with opener.open(req, timeout=30):
            return 0
    except urllib.error.HTTPError as exc:
        if 300 <= exc.code < 400:
            print("[webhook] post refused redirect; configure the final webhook URL",
                  file=sys.stderr)
        else:
            print("[webhook] post failed: %s" % exc, file=sys.stderr)
        return 1
    except (urllib.error.URLError, OSError) as exc:
        print("[webhook] post failed: %s" % exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
