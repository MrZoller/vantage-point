#!/usr/bin/env bash
# email-lib.sh - shared email rendering/sending helpers, sourced by bin/monitor.sh and
# bin/bootstrap.sh. Turns a Markdown body into a polished multipart/alternative email
# (styled HTML + plain-text fallback) via msmtp. Dependency-light, ASCII-only source,
# works on macOS bash 3.2. Callers set the chrome (VP_TITLE/VP_SUBTITLE/VP_PREHEADER/
# VP_FOOTER) and pass the subject; send_email does the rest.

# RFC 2047-encode a header value if it contains non-ASCII bytes (raw UTF-8 in mail
# headers isn't portable). Pure-ASCII values pass through unchanged.
encode_header() {  # <text> -> stdout: header-safe value
  local s="$1"
  # Detect non-ASCII bytes in pure bash (no external tool), so this stays correct
  # even on a minimal PATH where grep is absent - a missing grep must never let raw
  # UTF-8 ship un-encoded in a header. The C locale makes the bracket range match
  # raw bytes 0x20-0x7e (printable ASCII); anything outside it triggers encoding.
  if ( LC_ALL=C; case "$s" in *[!\ -~]*) exit 0 ;; *) exit 1 ;; esac ); then
    printf '=?UTF-8?B?%s?=' "$(printf '%s' "$s" | base64 | tr -d '\n')"
  else
    printf '%s' "$s"
  fi
}

# Pick the first available markdown->HTML renderer (none -> empty string).
# Always returns 0 so `renderer="$(md_renderer)"` is safe under `set -e` when no
# renderer is installed (the common case).
md_renderer() {
  local r
  for r in pandoc cmark-gfm cmark; do
    command -v "$r" >/dev/null 2>&1 && { echo "$r"; return 0; }
  done
  return 0
}

# stdin: markdown -> stdout: HTML fragment. Returns nonzero if no renderer exists,
# so callers can fall back to plain text. Bare URLs become clickable where the
# renderer supports autolinking (pandoc gfm, cmark-gfm).
render_md_to_html() {
  case "$(md_renderer)" in
    pandoc)    pandoc -f gfm -t html ;;
    cmark-gfm) cmark-gfm -e autolink -e table -e strikethrough -e tagfilter ;;
    cmark)     cmark ;;
    *)         return 1 ;;
  esac
}

# Minimal HTML escape for values we drop into the template chrome (subject, etc.).
# bash 5.2+ defaults patsub_replacement ON, which expands '&' in a ${//} replacement
# to the matched text and would mangle < / > into <lt; / >gt;; disable it so the
# replacements stay literal (no-op on bash 3.2, which has no such option).
_esc() {
  local s="$1"
  shopt -u patsub_replacement 2>/dev/null || true
  s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"
  printf '%s' "$s"
}

# <markdown-file> -> stdout: a one-line inbox preview (first non-heading line, with a
# leading blockquote marker and markdown emphasis/code marks stripped, trimmed). Pure
# bash so it needs no extra tools on a minimal PATH.
email_preheader() {  # <markdown-file>
  local line preheader=""
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    case "$line" in
      '#'*) continue ;;                 # skip markdown headings
      '> '*) line="${line#> }" ;;       # unwrap a leading blockquote marker
      '>'*)  line="${line#>}" ;;
    esac
    [ -n "$line" ] || continue
    line="${line//\*/}"; line="${line//\`/}"   # drop markdown emphasis/code marks
    preheader="${line:0:160}"; break
  done < "$1"
  printf '%s' "$preheader"
}

# stdin: HTML body fragment -> stdout: full styled HTML document. A <style> block
# (not inline styles) renders in the mail/preview clients this tool targets and keeps
# the template readable. Optional chrome is read from the environment so this stays a
# pure filter: VP_TITLE / VP_SUBTITLE (header), VP_PREHEADER (hidden inbox preview
# text), VP_FOOTER (footer line). Each is HTML-escaped. No external assets/images
# (privacy + reliability) and ASCII-only source per the repo convention.
wrap_html() {
  local title subtitle preheader footer
  title="$(_esc "${VP_TITLE:-}")"; subtitle="$(_esc "${VP_SUBTITLE:-}")"
  preheader="$(_esc "${VP_PREHEADER:-}")"; footer="$(_esc "${VP_FOOTER:-}")"
  cat <<'HTML_HEAD'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  body { margin: 0; padding: 0; background: #eef1f5; -webkit-font-smoothing: antialiased;
         font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
         color: #1f2933; line-height: 1.55; }
  .preheader { display: none !important; visibility: hidden; opacity: 0; height: 0; width: 0; overflow: hidden; }
  .wrap { max-width: 640px; margin: 0 auto; background: #ffffff; }
  .hd { padding: 28px 32px 22px; border-top: 4px solid #2f5bea; border-bottom: 1px solid #e6e9ef; }
  .eyebrow { font-size: 11px; letter-spacing: 0.12em; font-weight: 700; color: #2f5bea; text-transform: uppercase; }
  .title { font-size: 22px; font-weight: 700; line-height: 1.2; margin-top: 5px; color: #10151f; }
  .sub { font-size: 13px; color: #6b7280; margin-top: 5px; }
  .body { padding: 6px 32px 22px; }
  .body h1, .body h2, .body h3 { line-height: 1.25; color: #10151f; }
  .body h1 { font-size: 19px; margin: 22px 0 8px; }
  .body h2 { font-size: 14px; margin: 26px 0 10px; padding-bottom: 6px; border-bottom: 1px solid #eceef2;
             text-transform: uppercase; letter-spacing: 0.05em; color: #4b5563; }
  .body h3 { font-size: 15px; margin: 18px 0 4px; }
  .body p { margin: 9px 0; }
  .body a { color: #2f5bea; text-decoration: none; }
  .body a:hover { text-decoration: underline; }
  .body ul, .body ol { padding-left: 20px; margin: 9px 0; }
  .body li { margin: 7px 0; }
  .body blockquote { margin: 16px 0; padding: 14px 18px; background: #f3f6ff; border-left: 4px solid #2f5bea;
                     border-radius: 0 6px 6px 0; color: #28324a; font-size: 15px; }
  .body blockquote p { margin: 0; }
  .body code { background: #f1f3f7; padding: 1px 5px; border-radius: 4px; font-size: 0.92em; }
  .body pre { background: #0f172a; color: #e2e8f0; padding: 14px; border-radius: 8px; overflow-x: auto; }
  .body pre code { background: none; padding: 0; color: inherit; }
  .body hr { border: 0; border-top: 1px solid #e6e9ef; margin: 22px 0; }
  .body table { border-collapse: collapse; width: 100%; margin: 12px 0; font-size: 14px; }
  .body th { text-align: left; background: #f7f8fa; border-bottom: 2px solid #e6e9ef; padding: 8px 10px;
             font-size: 12px; text-transform: uppercase; letter-spacing: 0.03em; color: #6b7280; }
  .body td { border-bottom: 1px solid #eef1f5; padding: 8px 10px; }
  .body td.spark { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; color: #2f5bea; }
  .ft { padding: 16px 32px 26px; border-top: 1px solid #e6e9ef; color: #9aa3af; font-size: 12px; }
  .ft a { color: #6b7280; }
</style>
</head>
<body>
HTML_HEAD
  printf '<span class="preheader">%s</span>\n' "$preheader"
  printf '<div class="wrap">\n'
  if [ -n "$title" ]; then
    printf '<div class="hd"><div class="eyebrow">Vantage Point</div><div class="title">%s</div>' "$title"
    [ -n "$subtitle" ] && printf '<div class="sub">%s</div>' "$subtitle"
    printf '</div>\n'
  fi
  printf '<div class="body">\n'
  cat
  printf '\n</div>\n'
  [ -n "$footer" ] && printf '<div class="ft">%s</div>\n' "$footer"
  cat <<'HTML_FOOT'
</div>
</body>
</html>
HTML_FOOT
}

# Send a Markdown body as a polished email. Multipart/alternative (plain markdown +
# rendered HTML) when a renderer is available; otherwise a utf-8 plain-text message.
# The body file is unchanged on disk. The caller sets the VP_* chrome (read by
# wrap_html via dynamic scope) and passes the raw subject. Returns msmtp's exit status.
send_email() {  # <to> <subject> <body-markdown-file>
  local to="$1" subject body="$3"
  subject="$(encode_header "$2")"   # RFC 2047 if it has non-ASCII chars
  local html
  if html="$(render_md_to_html < "$body" 2>/dev/null)" && [ -n "$html" ]; then
    local boundary="vp-$$-${VP_BOUNDARY:-0}"
    {
      printf 'To: %s\n' "$to"
      printf 'Subject: %s\n' "$subject"
      printf 'MIME-Version: 1.0\n'
      printf 'Content-Type: multipart/alternative; boundary="%s"\n\n' "$boundary"
      printf -- '--%s\n' "$boundary"
      printf 'Content-Type: text/plain; charset=utf-8\n'
      printf 'Content-Transfer-Encoding: 8bit\n\n'
      cat "$body"; printf '\n'
      printf -- '--%s\n' "$boundary"
      printf 'Content-Type: text/html; charset=utf-8\n'
      printf 'Content-Transfer-Encoding: 8bit\n\n'
      printf '%s\n' "$html" | wrap_html
      printf '\n--%s--\n' "$boundary"
    } | msmtp "$to"
  else
    # No renderer (or render failed): plain text, but declare utf-8 so the
    # bullets/arrows/em-dashes don't get mangled.
    {
      printf 'To: %s\n' "$to"
      printf 'Subject: %s\n' "$subject"
      printf 'MIME-Version: 1.0\n'
      printf 'Content-Type: text/plain; charset=utf-8\n'
      printf 'Content-Transfer-Encoding: 8bit\n\n'
      cat "$body"
    } | msmtp "$to"
  fi
}
