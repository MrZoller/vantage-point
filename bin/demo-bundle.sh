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

# The canonical dependency-light config readers (cfg_get) -- so we honor a custom
# monitoring.state_file exactly as monitor.sh and portal.py do, instead of reimplementing
# the parse. Optional: if it's somehow absent we degrade to the default state path.
if [ -f "$ROOT/bin/config-lib.sh" ]; then
  # shellcheck source=bin/config-lib.sh
  . "$ROOT/bin/config-lib.sh"
fi

OUT="$ROOT/dist/vantage-point-demo"
MAKE_TAR=0
FORCE=0
# A bundle-specific sentinel we drop in every bundle, so --force only ever overwrites a
# folder THIS script created -- not, say, an unrelated docs/demo folder that happens to
# carry its own generic START-HERE.md.
MARKER=".vp-demo-bundle"

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

# Resolve OUT to a canonical absolute path so cp/tar behave regardless of the working
# dir AND the safety checks below can't be sidestepped by '.', '..', or symlink
# spellings. (os.path.realpath is lexical-plus-symlink and works on a not-yet-existing
# path, so it's safe to canonicalize the destination before we create it.)
abspath() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
case "$OUT" in /*) ;; *) OUT="$ROOT/$OUT" ;; esac
OUT="$(abspath "$OUT")"
ROOT_ABS="$(abspath "$ROOT")"

# Guard rails for the `rm -rf` below: --force must only ever replace a bundle, never
# the filesystem root, the repo checkout, or any ancestor of it. Without this a stray
# `--out . --force` (or `--out ..`) would delete the live config, state, kb, and even
# this script. These checks run BEFORE any deletion.
if [ "$OUT" = "/" ] || [ "$OUT" = "$ROOT_ABS" ]; then
  echo "demo-bundle.sh: refusing --out $OUT (the filesystem root or the repo itself)" >&2
  exit 2
fi
case "$ROOT_ABS/" in
  "$OUT"/*)
    echo "demo-bundle.sh: refusing --out $OUT (an ancestor of the repo -- deleting it would wipe the checkout)" >&2
    exit 2 ;;
esac

# Refuse a destination inside a tree we copy wholesale (state/, kb/): cp -R would then
# recurse the parent into its own descendant ("cannot copy a directory into itself"),
# leaving a half-built bundle nested in the live data.
for tree in state kb; do
  case "$OUT/" in
    "$ROOT_ABS/$tree"/*)
      echo "demo-bundle.sh: refusing --out $OUT (inside the $tree/ tree this script copies)" >&2
      exit 2 ;;
  esac
done

# Refuse to clobber an existing destination unless --force (a bundle is cheap to
# rebuild, but blowing away the wrong directory is not).
if [ -e "$OUT" ]; then
  if [ "$FORCE" -ne 1 ]; then
    echo "demo-bundle.sh: $OUT already exists (use --force to overwrite)" >&2
    exit 1
  fi
  # A bundle is always a directory; refuse an existing file/symlink/other so a stray
  # --force can't delete e.g. the live profile.yaml ('--out profile.yaml --force').
  if [ ! -d "$OUT" ]; then
    echo "demo-bundle.sh: refusing --force on $OUT (an existing non-directory; a bundle is a folder)" >&2
    exit 1
  fi
  # And even for a directory, only replace a *previous bundle* (identified by the
  # bundle-specific .vp-demo-bundle sentinel we write, not a generic filename) or an
  # empty one -- never an arbitrary populated directory we didn't create.
  if [ ! -f "$OUT/$MARKER" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ]; then
    echo "demo-bundle.sh: refusing to --force-overwrite $OUT (not empty and not a previous demo bundle)" >&2
    exit 1
  fi
  rm -rf "$OUT"
fi

# Treat <out>.tar.gz as an output artifact too: don't silently clobber an existing
# archive unless --force, mirroring the folder guard above.
TARBALL="$OUT.tar.gz"
if [ "$MAKE_TAR" -eq 1 ] && [ -e "$TARBALL" ] && [ "$FORCE" -ne 1 ]; then
  echo "demo-bundle.sh: $TARBALL already exists (use --force to overwrite)" >&2
  exit 1
fi

mkdir -p "$OUT/bin"
# Stamp the bundle so a later --force can recognize it (see the guard above).
printf 'vantage-point demo bundle -- created by bin/demo-bundle.sh\n' > "$OUT/$MARKER"

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
    # Dereference valid symlinks so an off-site bundle cannot point back into live state,
    # but omit dangling ones individually. Plain `cp -RL` aborts the entire build on one
    # broken link; Python is already a required runtime and lets other copy errors remain
    # fatal rather than hiding permissions, disk-full, or traversal failures.
    python3 - "$ROOT/$1" "$OUT/$1" "$1" <<'PY'
import errno
import os
import shutil
import sys

source, destination, relative_root = sys.argv[1:]


def skip_dangling(directory, names):
    skipped = []
    for name in names:
        path = os.path.join(directory, name)
        if not os.path.islink(path):
            continue
        try:
            os.stat(path)
        except OSError as error:
            if error.errno not in (errno.ENOENT, errno.ENOTDIR):
                raise
            relative = os.path.relpath(path, source)
            print(
                "demo-bundle.sh: WARNING: "
                f"{os.path.join(relative_root, relative)} is a dangling symlink - skipped",
                file=sys.stderr,
            )
            skipped.append(name)
    return skipped


shutil.copytree(source, destination, ignore=skip_dangling)
PY
    copied_any=1
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

# 2b) The dedup state file the portal scores against is monitoring.state_file (default
# state/seen.jsonl); portal.py's resolve_state_file() honors a custom or absolute path.
# A relative path under state/ rode along with the copy above and stays valid against
# the bundle root. Anything else (an absolute path, or a relative path outside state/)
# would, in the bundled config, still point at the ORIGINAL machine -- an empty Overview
# off-machine, or live state read on the original. So copy that file into the bundle's
# state/ and repoint the bundled config at a portable relative path.
rewrite_state_file() {  # <config-file> <new-relative-value>
  local cfg="$1" nv="$2" tmp
  tmp="$(mktemp)"
  awk -v nv="$nv" '
    $0 ~ "^monitoring:[[:space:]]*(#.*)?$" { print; inblk=1; next }
    inblk && /^[^[:space:]#]/ { inblk=0 }
    inblk && $1 == "state_file:" {
      match($0, /^[[:space:]]*/); print substr($0,1,RLENGTH) "state_file: " nv; next
    }
    { print }
  ' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
}

if command -v cfg_get >/dev/null 2>&1 && [ -f "$OUT/monitor-config.yaml" ]; then
  sf="$(cfg_get monitoring state_file "$ROOT/monitor-config.yaml")"
  [ -n "$sf" ] || sf="state/seen.jsonl"
  case "$sf" in ./*) sf="${sf#./}" ;; esac
  # Portable iff it's a relative path under state/ (already bundled, resolves against the
  # bundle root). Absolute or outside-state/ paths need relocating.
  portable=0
  case "$sf" in
    /*) ;;                      # absolute -> not portable
    state/*) portable=1 ;;      # relative under state/ -> already in the bundle
  esac
  if [ "$portable" -eq 0 ]; then
    case "$sf" in /*) sf_src="$sf" ;; *) sf_src="$ROOT/$sf" ;; esac
    if [ -f "$sf_src" ]; then
      base="$(basename "$sf_src")"
      mkdir -p "$OUT/state"
      dest="state/$base"
      # Don't overwrite a real bundled state file (e.g. feedback.jsonl grades) if the
      # external state_file shares its basename -- namespace it instead.
      if [ -e "$OUT/$dest" ]; then dest="state/statefile-$base"; fi
      if [ -e "$OUT/$dest" ]; then
        echo "demo-bundle.sh: WARNING: configured state_file ($sf) collides with bundled" \
             "state data; left the demo config unchanged rather than overwrite it" >&2
      else
        cp "$sf_src" "$OUT/$dest"
        rewrite_state_file "$OUT/monitor-config.yaml" "$dest"
        copied_any=1
        echo "demo-bundle.sh: NOTE: bundled the configured state_file ($sf) as $dest" \
             "and repointed the demo config" >&2
      fi
    else
      echo "demo-bundle.sh: WARNING: configured state_file ($sf) not found -" \
           "the demo Overview's surfaced-items view may be empty" >&2
    fi
  fi
fi

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

# 6) Optional tarball for easy carrying (TARBALL was validated against --force above).
tarmsg=""
if [ "$MAKE_TAR" -eq 1 ]; then
  tarbase="$(basename "$OUT")"
  rm -f "$TARBALL"
  ( cd "$(dirname "$OUT")" && tar -czf "$TARBALL" "$tarbase" )
  tarmsg="  tarball: $TARBALL"$'\n'
fi

bytes="$(du -sh "$OUT" 2>/dev/null | cut -f1 || echo '?')"
printf 'Demo bundle ready.\n'
printf '  folder:  %s  (%s)\n' "$OUT" "$bytes"
[ -n "$tarmsg" ] && printf '%s' "$tarmsg"
printf '  smoke:   %s\n' "$smoke"
printf '\nRun the demo:\n  cd %s && ./start-demo.sh\n' "$OUT"
