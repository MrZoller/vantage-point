#!/usr/bin/env bash
# config-lib.sh - dependency-light YAML scalar readers (plus the long-lived Claude token
# loader at the bottom), sourced by bin/monitor.sh, bin/bootstrap.sh and bin/init.sh. No YAML library: small awk that walks a top-level `block:` and
# pulls one `key:`. The default file is the caller's $CONFIG (dynamic scope). ASCII
# only; works on macOS bash 3.2.

# Read a single scalar `key:` nested under a top-level YAML `block:` from a config
# file. Prints the value (comment/quotes/space stripped) or nothing.
#
# Returns 0 for a MISSING KEY in a readable file - that is the case callers mean when they
# write `x="$(cfg_get ...)"` under set -e. It deliberately does NOT swallow an I/O failure:
# if the file is missing or unreadable, awk's nonzero status propagates and the caller
# dies. That is the right default, because a config that cannot be read is not the same as
# a config with nothing in it - silently substituting empty would let a run continue with
# no delivery settings and no rubric while still writing state. A caller that genuinely
# wants tolerance opts in at the call site with `|| true`, where the intent is visible.
# NOTE: matches `key:` at ANY indentation within the block (first match wins), so don't
# add a sub-block whose child key collides with a sibling key you read from that block.
cfg_get() {  # <block> <key> [file=$CONFIG]
  awk -v blk="$1" -v key="$2" '
    $0 ~ "^" blk ":[[:space:]]*(#.*)?$" { inblk=1; next }
    inblk && /^[^[:space:]#]/           { inblk=0 }
    inblk && $1 == key":" {
      line=$0
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", line)   # drop "  key: "
      sub(/^#.*$/, "", line)                             # value is only a comment -> empty
      sub(/[[:space:]]+#.*$/, "", line)                  # drop a real trailing comment
      gsub(/[[:space:]]/, "", line)                      # drop surrounding space
      gsub(/["\047]/, "", line)                          # drop quotes
      print line; exit
    }
  ' "${3:-$CONFIG}"
}

# Like cfg_get but PRESERVES internal spaces - for human-readable values such as
# subject.name. Trims ends, unwraps a surrounding quote pair (keeping internal
# quotes, handling YAML \" and '' escapes), or for an unquoted value drops only a
# real trailing "# comment" (whitespace before #, so e.g. "C# tools" is kept).
cfg_get_text() {  # <block> <key> [file=$CONFIG]
  awk -v blk="$1" -v key="$2" '
    $0 ~ "^" blk ":[[:space:]]*(#.*)?$" { inblk=1; next }
    inblk && /^[^[:space:]#]/           { inblk=0 }
    inblk && $1 == key":" {
      line=$0
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", line)   # drop "  key: "
      sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
      if (line ~ /^"/) {                                 # double-quoted scalar
        sub(/^"/, "", line)
        sub(/"[[:space:]]*(#.*)?$/, "", line)            # closing quote (+ trailing comment)
        gsub(/\\"/, "\"", line)                          # YAML \" -> "
      } else if (line ~ /^\047/) {                       # single-quoted scalar
        sub(/^\047/, "", line)
        sub(/\047[[:space:]]*(#.*)?$/, "", line)
        gsub(/\047\047/, "\047", line)                   # YAML doubled single-quote escape
      } else {                                           # unquoted scalar
        sub(/^#.*$/, "", line)                           # value is only a comment -> empty
        sub(/[[:space:]]+#.*$/, "", line)                # comment only after whitespace
        sub(/[[:space:]]+$/, "", line)
      }
      print line; exit
    }
  ' "${3:-$CONFIG}"
}

# Read a boolean `key:` under a top-level `block:`. Prints "1" for a truthy value
# (true/yes/on/1, any case) and "" otherwise. The third arg is the default applied
# when the key is absent/blank (pass 1 for default-on, 0/omit for default-off).
# Always returns 0, so `x="$(cfg_get_bool ...)"` is safe under set -e.
cfg_get_bool() {  # <block> <key> [default=0] [file=$CONFIG]
  local v; v="$(cfg_get "$1" "$2" "${4:-$CONFIG}")"
  [ -n "$v" ] || v="${3:-0}"
  case "$v" in
    1|[tT][rR][uU][eE]|[yY][eE][sS]|[oO][nN]) printf '1' ;;
    *) printf '' ;;
  esac
}

# Read a `key:` under a top-level `block:` as a LIST, printing one item per line.
# Accepts every shape a human is likely to write, so existing single-address configs
# keep working untouched:
#   key: one@x.com            -> a bare scalar          (one item)
#   key: "a@x.com, b@x.com"   -> a comma-joined scalar  (split into items)
#   key: [a@x.com, b@x.com]   -> an inline flow list
#   key:                      -> a block list:
#     - a@x.com
#     - b@x.com
# Comments/quotes/surrounding space are stripped; blank items are dropped. Always
# returns 0, so `while read ...; done < <(cfg_get_list ...)` is safe under set -e.
cfg_get_list() {  # <block> <key> [file=$CONFIG]
  awk -v blk="$1" -v key="$2" '
    # Split one raw value on commas and print each non-empty, de-quoted piece.
    function emit(v,   n, parts, i, p) {
      sub(/[[:space:]]+#.*$/, "", v)                  # drop a trailing "# comment"
      n = split(v, parts, ",")
      for (i = 1; i <= n; i++) {
        p = parts[i]
        sub(/^[[:space:]]+/, "", p); sub(/[[:space:]]+$/, "", p)
        gsub(/^["\047]|["\047]$/, "", p)              # strip one wrapping quote pair
        sub(/^[[:space:]]+/, "", p); sub(/[[:space:]]+$/, "", p)
        if (p != "") print p
      }
    }
    $0 ~ "^" blk ":[[:space:]]*(#.*)?$" { inblk=1; next }
    # Once reading a block list, consume "- item" lines (and skip blanks/comments)
    # until any other line ends it - we only ever collect one key.
    inblk && inlist {
      if ($0 ~ /^[[:space:]]*-[[:space:]]*/) {
        item=$0; sub(/^[[:space:]]*-[[:space:]]*/, "", item); emit(item); next
      } else if ($0 ~ /^[[:space:]]*(#.*)?$/) {
        next
      } else { exit }
    }
    inblk && /^[^[:space:]#]/ { inblk=0 }
    inblk && $1 == key":" {
      line=$0
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", line)   # drop "  key: "
      sub(/^#.*$/, "", line)                             # value is only a comment
      sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
      if (line ~ /^\[/) {                                # inline flow list [a, b]
        sub(/^\[/, "", line); sub(/\][[:space:]]*(#.*)?$/, "", line)
        emit(line); exit
      } else if (line != "") {                           # scalar (maybe comma-joined)
        emit(line); exit
      } else { inlist=1; next }                          # bare "key:" -> block list
    }
  ' "${3:-$CONFIG}"
}

# ---- long-lived Claude auth for unattended runs ----
# Scheduled runs are headless, so `claude -p` leans on the interactive login's OAuth
# refresh token - which lapses every few weeks, and from then on every run fails until
# someone re-runs /login on the host. `claude setup-token` mints a year-long token
# instead. Save it (alone, on one line) to $VP_CLAUDE_TOKEN_FILE, default
# ~/.config/vantage-point/claude-token, chmod 600: one file serves every checkout on
# the machine. The agents export it as CLAUDE_CODE_OAUTH_TOKEN, which the CLI uses ahead
# of the stored login. No file = the stored login, exactly as before. A token already in
# the environment wins, so a caller can still override it for one run. Fail-safe: an
# unreadable or empty file is a stderr note and a fallback, never a dead run.
claude_token_file() { printf '%s' "${VP_CLAUDE_TOKEN_FILE:-$HOME/.config/vantage-point/claude-token}"; }
load_claude_token() {
  local f tok perms
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    VP_CLAUDE_TOKEN_FROM_ENV=1      # so a failure email blames the right credential
    return 0
  fi
  f="$(claude_token_file)"
  [ -e "$f" ] || return 0
  if [ ! -r "$f" ]; then
    echo "[auth] note: $f is not readable - using the stored claude login" >&2
    return 0
  fi
  # First non-blank, non-comment line, all whitespace removed (a pasted token often
  # carries a trailing newline or stray spaces; a real token never contains one).
  tok="$(awk '!/^[[:space:]]*(#|$)/ { gsub(/[[:space:]]/, ""); print; exit }' "$f" 2>/dev/null || true)"
  if [ -z "$tok" ]; then
    echo "[auth] note: $f has no token - using the stored claude login" >&2
    return 0
  fi
  # Group- or other-readable? `find -perm -NNN` is portable across BSD/GNU, unlike stat.
  # -H follows a symlinked token file to its target: a link's own mode is always 755.
  perms="$(find -H "$f" -prune \( -perm -040 -o -perm -004 \) -print 2>/dev/null || true)"
  [ -z "$perms" ] || echo "[auth] WARNING: $f is readable by other users - chmod 600 it" >&2
  export CLAUDE_CODE_OAUTH_TOKEN="$tok"
  VP_CLAUDE_TOKEN_LOADED="$f"
}

# Markdown paragraph for a failure email when <text> (a failure reason or an stderr tail)
# reads as a claude auth failure; prints nothing otherwise. The fix differs by where the
# credential came from, so say which one failed rather than a generic "log in again".
claude_auth_hint() {  # <text>
  printf '%s' "$1" | grep -Eqi 'authenticat|oauth|/login|invalid api key' || return 0
  # shellcheck disable=SC2016  # backticks are literal Markdown
  if [ -n "${VP_CLAUDE_TOKEN_FROM_ENV:-}" ]; then
    printf '**Fix:** the `CLAUDE_CODE_OAUTH_TOKEN` this run inherited from its environment was rejected (expired or revoked). Mint a new one with `claude setup-token` and update wherever that variable is set.\n\n'
  elif [ -n "${VP_CLAUDE_TOKEN_LOADED:-}" ]; then
    printf '**Fix:** the saved token in `%s` was rejected (expired or revoked). Mint a new one on the host with `claude setup-token` and replace the file'"'"'s contents.\n\n' "$VP_CLAUDE_TOKEN_LOADED"
  else
    printf '**Fix:** the stored `claude` login has lapsed, and it will keep lapsing every few weeks. On the host, run `claude setup-token` and save the token it prints to `%s` (`chmod 600`). Every scheduled run then uses that year-long token instead.\n\n' "$(claude_token_file)"
  fi
}
