#!/usr/bin/env bash
# review.sh [--port N] -- launch the grading UI (bin/feedback-server.py): thumbs
# up/down on recent surfaced items, recorded to state/feedback.jsonl for the next
# bootstrap to calibrate the rubric from. Localhost-only; reach it over an
# SSH-forwarded port or VS Code Remote, same as `dashboard.sh --serve`.
#
#   ./bin/review.sh             # serve the grading UI on http://localhost:8000
#   ./bin/review.sh --port 8090
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PORT=8000
case "${1:-}" in
  "") ;;
  --port)
    case "${2:-}" in ''|*[!0-9]*) echo "usage: review.sh [--port N]" >&2; exit 2 ;; esac
    PORT="$2" ;;
  -h|--help) echo "usage: review.sh [--port N]   (grade surfaced items; default port 8000)"; exit 0 ;;
  *) echo "usage: review.sh [--port N]" >&2; exit 2 ;;
esac

command -v python3 >/dev/null 2>&1 || { echo "python3 not found - cannot serve the review UI" >&2; exit 1; }

# Refresh the dashboard too, best-effort, so it's current alongside grading.
if [ -f bin/dashboard.sh ]; then bash bin/dashboard.sh >/dev/null 2>&1 || true; fi

exec python3 bin/feedback-server.py "$PORT"
