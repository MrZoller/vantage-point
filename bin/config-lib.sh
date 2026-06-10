#!/usr/bin/env bash
# config-lib.sh - dependency-light YAML scalar readers, sourced by bin/monitor.sh and
# bin/bootstrap.sh. No YAML library: small awk that walks a top-level `block:` and
# pulls one `key:`. The default file is the caller's $CONFIG (dynamic scope). ASCII
# only; works on macOS bash 3.2.

# Read a single scalar `key:` nested under a top-level YAML `block:` from a config
# file. Prints the value (comment/quotes/space stripped) or nothing. Always returns 0,
# so `x="$(cfg_get ...)"` is safe under set -e.
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
