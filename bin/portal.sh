#!/usr/bin/env bash
# portal.sh -- launch the unified web portal (bin/portal.py): Overview (tracked
# entities + sparklines), Reports (daily/weekly briefings rendered like their email),
# Review (thumbs up/down -> state/feedback.jsonl), Profile and Config (read-only). It
# replaces the old dashboard.sh + review.sh. Localhost-only; reach it over an
# SSH-forwarded port or VS Code Remote.
#
#   ./bin/portal.sh                 # serve on http://localhost:8000
#   ./bin/portal.sh --port 8090     # ...or pick a port
#   ./bin/portal.sh --export        # just (re)write kb/index.html, no server
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PORT=8000
case "${1:-}" in
  "") ;;
  --port)
    case "${2:-}" in ''|*[!0-9]*) echo "usage: portal.sh [--port N | --export]" >&2; exit 2 ;; esac
    PORT="$2" ;;
  --export)
    exec python3 bin/portal.py --export ;;
  -h|--help)
    printf 'usage: portal.sh [--port N | --export]\n'
    printf '  (no args)      serve the portal on http://localhost:%s\n' "$PORT"
    printf '  --port N       ...on port N\n'
    printf '  --export       (re)write kb/index.html and exit (no server)\n'
    exit 0 ;;
  *) echo "usage: portal.sh [--port N | --export]" >&2; exit 2 ;;
esac

command -v python3 >/dev/null 2>&1 || { echo "python3 not found - cannot serve the portal" >&2; exit 1; }

exec python3 bin/portal.py "$PORT"
