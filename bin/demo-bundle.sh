#!/usr/bin/env bash
# demo-bundle.sh -- package the web portal plus the data it has accumulated locally
# into one self-contained, portable folder you can carry to another machine and serve
# with nothing but python3. Built for showing the portal off-site (a work demo, a
# laptop) WITHOUT running the agent there: you just start the web server.
#
# What it copies:
#   - the portal runtime  -> <out>/bin/{portal.py,portal.sh,cadence.py}
#   - the live data        -> <out>/{monitor-config.yaml,profile.yaml,profile.*,state/,kb/}
#   - a launcher + a note  -> <out>/{start-demo.sh,START-HERE.md}
# The portal's only repo dependency is bin/cadence.py (loaded by path); markdown
# renders via pandoc/cmark when present and a built-in pure-python fallback otherwise,
# so the bundle runs anywhere python3 does -- no agent, no claude CLI, no network.
#
#   ./bin/demo-bundle.sh                    # -> dist/vantage-point-demo/
#   ./bin/demo-bundle.sh --out /tmp/demo    # ...to a chosen folder
#   ./bin/demo-bundle.sh --tar              # ...and also write <out>.tar.gz
#   ./bin/demo-bundle.sh --force            # overwrite an existing <out>
#
# NOTE: the bundle contains your real monitor-config.yaml and profile.yaml verbatim
# (the portal's Config/Profile tabs show them), so it carries recipient emails, any
# output.webhook_url, and the profile's competitive-intel text. Treat the bundle as
# you would those files.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT="$ROOT/dist/vantage-point-demo"
MAKE_TAR=0
FORCE=0

usage() {
  printf 'usage: demo-bundle.sh [--out DIR] [--tar] [--force]\n'
  printf '  --out DIR   destination folder for the bundle (default: dist/vantage-point-demo)\n'
  printf '  --tar       also write a <out>.tar.gz alongside the folder\n'
  printf '  --force     overwrite the destination if it already exists\n'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --out)
      case "${2:-}" in ''|--*) echo "demo-bundle.sh: --out needs a path" >&2; exit 2 ;; esac
      OUT="$2"; shift 2 ;;
    --tar)   MAKE_TAR=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "demo-bundle.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || { echo "python3 not found - the portal needs it to serve" >&2; exit 1; }

# Resolve OUT to an absolute path so cp/tar behave regardless of the working dir, and
# refuse to clobber an existing folder unless --force (a bundle is cheap to rebuild,
# but blowing away the wrong directory is not).
case "$OUT" in /*) ;; *) OUT="$ROOT/$OUT" ;; esac
if [ -e "$OUT" ]; then
  if [ "$FORCE" -eq 1 ]; then
    rm -rf "$OUT"
  else
    echo "demo-bundle.sh: $OUT already exists (use --force to overwrite)" >&2
    exit 1
  fi
fi

mkdir -p "$OUT/bin"

# 1) Portal runtime. portal.sh + portal.py are required; cadence.py is the one sibling
# portal.py loads (the dossier Cadence line) and degrades gracefully if absent, but we
# always ship it so the demo is complete.
for f in portal.py portal.sh cadence.py; do
  if [ -f "$ROOT/bin/$f" ]; then
    cp "$ROOT/bin/$f" "$OUT/bin/$f"
  else
    echo "demo-bundle.sh: WARNING: bin/$f is missing - the portal may be incomplete" >&2
  fi
done
chmod +x "$OUT/bin/portal.sh" 2>/dev/null || true

# 2) Live data. Copy whatever exists; the bundle is useful even if some pieces are
# absent (e.g. no profile yet). Warn on the load-bearing ones so the gap is visible.
copied_any=0
copy_file() {  # copy_file <src-relative> [warn]
  if [ -f "$ROOT/$1" ]; then
    cp "$ROOT/$1" "$OUT/$1"; copied_any=1
  elif [ "${2:-}" = "warn" ]; then
    echo "demo-bundle.sh: WARNING: $1 not found - its portal tab will be empty" >&2
  fi
}
copy_dir() {   # copy_dir <src-relative> [warn]
  if [ -d "$ROOT/$1" ]; then
    cp -R "$ROOT/$1" "$OUT/$1"; copied_any=1
  elif [ "${2:-}" = "warn" ]; then
    echo "demo-bundle.sh: WARNING: $1/ not found - its portal tab will be empty" >&2
  fi
}

copy_file monitor-config.yaml warn
copy_file profile.yaml warn
# Optional profile digests/draft artifacts the Profile tab renders when present.
for f in profile.summary.md profile.draft.yaml profile.draft.summary.md \
         profile.draft.diff profile.draft.backtest.md profile.draft.feedcheck.md \
         profile.draft.challenge.md; do
  copy_file "$f"
done
copy_dir state warn
copy_dir kb warn

if [ "$copied_any" -eq 0 ]; then
  echo "demo-bundle.sh: WARNING: no data found to bundle (state/, kb/, profile.yaml," \
       "monitor-config.yaml all absent). The portal will start but show empty tabs." >&2
fi

# 3) A one-command launcher at the bundle root, so the demo machine never has to know
# the bin/ layout: just ./start-demo.sh [--port N].
cat > "$OUT/start-demo.sh" <<'LAUNCH'
#!/usr/bin/env bash
# Start the Vantage Point demo portal. Pass --port N to pick a port (default 8000).
# Open the printed URL in a browser; Ctrl-C to stop. No agent, no network needed.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$HERE/bin/portal.sh" "$@"
LAUNCH
chmod +x "$OUT/start-demo.sh"

# 4) A short orientation note for whoever unpacks the bundle.
cat > "$OUT/START-HERE.md" <<'NOTE'
# Vantage Point - portal demo bundle

A self-contained snapshot of the Vantage Point web portal, populated with real
accumulated data. It runs the portal **read-only-ish** (the Review tab still records
grades into this bundle's `state/feedback.jsonl`; nothing leaves the machine).

## Run it

    ./start-demo.sh            # serve on http://localhost:8000
    ./start-demo.sh --port 8090

Then open the printed URL in a browser. Ctrl-C to stop.

Requirements: `python3` (3.8+). That's it - no agent, no `claude` CLI, no network.
Markdown reports render via `pandoc`/`cmark` if installed, otherwise a built-in
fallback renderer (slightly plainer, fully functional).

## What's inside

- `bin/portal.py`, `bin/portal.sh`, `bin/cadence.py` - the portal runtime
- `monitor-config.yaml`, `profile.yaml` (+ any summaries/drafts) - shown read-only
- `state/`, `kb/` - the accumulated observations, grades, and rendered reports

The portal binds to `127.0.0.1` only.

> Heads up: this bundle contains the real `monitor-config.yaml` and `profile.yaml`,
> so it carries recipient emails, any webhook URL, and the profile's intel text.
> Treat it as sensitive.
NOTE

# 5) Smoke-test the bundle the same way the monitor does -- render the static Overview
# from the bundled data. Fail-safe: a render hiccup must not sink the bundle (the live
# server is the real artifact), so warn rather than abort.
if python3 "$OUT/bin/portal.py" --export >/dev/null 2>&1; then
  smoke="ok (Overview rendered)"
else
  smoke="skipped (static export did not render; the live server is unaffected)"
  echo "demo-bundle.sh: NOTE: static --export smoke test $smoke" >&2
fi

# 6) Optional tarball for easy carrying.
tarmsg=""
if [ "$MAKE_TAR" -eq 1 ]; then
  base="$(basename "$OUT")"
  tarball="$OUT.tar.gz"
  rm -f "$tarball"
  ( cd "$(dirname "$OUT")" && tar -czf "$tarball" "$base" )
  tarmsg="  tarball: $tarball"$'\n'
fi

bytes="$(du -sh "$OUT" 2>/dev/null | cut -f1 || echo '?')"
printf 'Demo bundle ready.\n'
printf '  folder:  %s  (%s)\n' "$OUT" "$bytes"
[ -n "$tarmsg" ] && printf '%s' "$tarmsg"
printf '  smoke:   %s\n' "$smoke"
printf '\nRun the demo:\n  cd %s && ./start-demo.sh\n' "$OUT"
