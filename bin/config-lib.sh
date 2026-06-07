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
