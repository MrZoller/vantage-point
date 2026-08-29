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

# stdin: HTML body fragment -> stdout: full styled HTML document. Structure is a
# table-based layout with bgcolor attributes + inline styles, because Outlook (the
# Word rendering engine) ignores embedded <style> rules, max-width and margin:auto,
# and padding on <div>s - so a <style>-only card left Outlook showing a grey page
# with the white card and body margins missing. The <style> block remains as a
# progressive enhancement (rich typography in Gmail / Apple Mail); the layout, page
# background, white card and gutters all come from the tables so it holds up in
# Outlook too. Optional chrome is read from the environment so this stays a pure
# filter: VP_TITLE / VP_SUBTITLE (header), VP_PREHEADER (hidden inbox preview text),
# VP_FOOTER (footer line). Each is HTML-escaped. By default the email carries NO
# images (privacy + reliability); a logo appears only when VP_LOGO_CID is set, in
# which case the header references a CID-embedded inline image (set up by send_email -
# never an external fetch). ASCII-only source per the repo convention.
wrap_html() {
  local title subtitle preheader footer logo_cid
  title="$(_esc "${VP_TITLE:-}")"; subtitle="$(_esc "${VP_SUBTITLE:-}")"
  preheader="$(_esc "${VP_PREHEADER:-}")"; footer="$(_esc "${VP_FOOTER:-}")"
  logo_cid="$(_esc "${VP_LOGO_CID:-}")"   # non-empty -> emit the CID logo image
  # Shared font stack, kept in one place. 'Segoe UI' carries a literal single quote;
  # holding it in a variable and passing it as a printf arg avoids any escaping.
  local ff="-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif"
  cat <<'HTML_HEAD'
<!DOCTYPE html>
<html lang="en" xmlns:o="urn:schemas-microsoft-com:office:office">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="X-UA-Compatible" content="IE=edge">
<!--[if mso]>
<noscript><xml><o:OfficeDocumentSettings><o:PixelsPerInch>96</o:PixelsPerInch></o:OfficeDocumentSettings></xml></noscript>
<![endif]-->
<style>
  /* Progressive typography for clients that honor embedded styles (Gmail, Apple
     Mail). Outlook ignores most of this; its layout/colors come from the table
     attributes + inline styles below, so the email stays readable either way. */
  body { margin: 0; padding: 0; background: #eef1f5; -webkit-font-smoothing: antialiased; }
  .body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
          color: #1f2933; line-height: 1.55; font-size: 15px; }
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
                     border-radius: 0 6px 6px 0; color: #28324a; }
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
  .preheader { display: none !important; visibility: hidden; opacity: 0; height: 0; width: 0; overflow: hidden; }
  /* Tighten the side gutters on narrow screens. */
  @media only screen and (max-width: 600px) {
    .gutter { padding-left: 12px !important; padding-right: 12px !important; }
    .pad { padding-left: 20px !important; padding-right: 20px !important; }
  }
</style>
</head>
<body style="margin:0; padding:0; background:#eef1f5;">
HTML_HEAD
  printf '<span class="preheader" style="display:none; max-height:0; overflow:hidden;">%s</span>\n' "$preheader"
  # Full-width page background (Outlook honors bgcolor on tables/cells) with a gutter
  # cell so the white card never touches the viewport edge (the "no margin" fix). The
  # mso conditional pins the card to 640px in Outlook, which lacks max-width.
  cat <<'HTML_OUTER'
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="#eef1f5" style="background:#eef1f5;">
<tr>
<td align="center" class="gutter" style="padding:24px 16px;">
<!--[if mso]><table role="presentation" width="640" cellpadding="0" cellspacing="0" border="0"><tr><td><![endif]-->
<table role="presentation" align="center" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="#ffffff" style="width:100%; max-width:640px; background:#ffffff;">
<tr><td style="height:4px; line-height:4px; font-size:4px; background:#2f5bea;">&nbsp;</td></tr>
HTML_OUTER
  if [ -n "$title" ]; then
    printf '<tr><td class="pad" style="padding:28px 32px 22px; border-bottom:1px solid #e6e9ef; font-family:%s;">' "$ff"
    # Optional brand mark: a CID-embedded inline image (send_email attaches the bytes).
    # width/height attributes + inline style keep Outlook honest; alt text covers the
    # images-off case so the header never collapses.
    [ -n "$logo_cid" ] && printf '<img src="cid:%s" width="40" height="40" alt="Vantage Point" style="display:block; border:0; width:40px; height:40px; margin:0 0 12px;">' "$logo_cid"
    printf '<div style="font-size:11px; letter-spacing:0.12em; font-weight:700; color:#2f5bea; text-transform:uppercase;">Vantage Point</div>'
    printf '<div style="margin-top:5px; font-size:22px; font-weight:700; line-height:1.2; color:#10151f;" class="title">%s</div>' "$title"
    [ -n "$subtitle" ] && printf '<div style="margin-top:5px; font-size:13px; color:#6b7280;" class="sub">%s</div>' "$subtitle"
    printf '</td></tr>\n'
  fi
  printf '<tr><td class="body pad" style="padding:6px 32px 22px; font-family:%s; color:#1f2933; line-height:1.55; font-size:15px;">\n' "$ff"
  cat
  printf '\n</td></tr>\n'
  [ -n "$footer" ] && printf '<tr><td class="pad" style="padding:16px 32px 26px; border-top:1px solid #e6e9ef; color:#9aa3af; font-size:12px; font-family:%s;">%s</td></tr>\n' "$ff" "$footer"
  cat <<'HTML_FOOT'
</table>
<!--[if mso]></td></tr></table><![endif]-->
</td>
</tr>
</table>
</body>
</html>
HTML_FOOT
}

# Print the two parts of a multipart/alternative body (plain markdown, then styled
# HTML) to stdout, using boundary $1. When a logo CID is given, it's exported to
# wrap_html so the HTML header references the CID-embedded image.
# Args: <alt-boundary> <body-markdown-file> <html-fragment> <logo-cid>.
_emit_alt_parts() {
  local boundary="$1" body="$2" html="$3" logo_cid="$4"
  printf -- '--%s\n' "$boundary"
  printf 'Content-Type: text/plain; charset=utf-8\n'
  printf 'Content-Transfer-Encoding: 8bit\n\n'
  cat "$body"; printf '\n'
  printf -- '--%s\n' "$boundary"
  printf 'Content-Type: text/html; charset=utf-8\n'
  printf 'Content-Transfer-Encoding: 8bit\n\n'
  printf '%s\n' "$html" | VP_LOGO_CID="$logo_cid" wrap_html
  printf '\n--%s--\n' "$boundary"
}

# stdin: bytes -> stdout: MIME-safe base64 with an explicit 76-character line
# limit. GNU base64 wraps by default, while the macOS tool emits one unbounded
# line; normalize both in Bash so sending does not depend on platform flags.
_emit_base64_body() {
  local encoded
  encoded="$(base64)"
  encoded="${encoded//$'\n'/}"
  encoded="${encoded//$'\r'/}"
  while [ "${#encoded}" -gt 76 ]; do
    printf '%.76s\n' "$encoded"
    encoded="${encoded:76}"
  done
  printf '%s\n' "$encoded"
}

# Print one HTML email (plain markdown + styled HTML) to stdout. With a readable logo
# PNG + CID, the message is multipart/related: the alternative body plus the logo as a
# base64 image/png part referenced by `cid:` from the header (inline, no external
# fetch). Without one, it's a plain multipart/alternative - identical to before.
# Args: <encoded-subject> <body-markdown-file> <html-fragment> <recipient> [logo-png] [logo-cid].
_emit_html() {
  local subject="$1" body="$2" html="$3" to="$4" logo="${5:-}" logo_cid="${6:-}"
  local alt="vp-alt-$$-${VP_BOUNDARY:-0}"
  printf 'To: %s\n' "$to"
  printf 'Subject: %s\n' "$subject"
  printf 'MIME-Version: 1.0\n'
  if [ -n "$logo" ] && [ -n "$logo_cid" ] && [ -r "$logo" ]; then
    local rel="vp-rel-$$-${VP_BOUNDARY:-0}"
    printf 'Content-Type: multipart/related; boundary="%s"\n\n' "$rel"
    printf -- '--%s\n' "$rel"
    printf 'Content-Type: multipart/alternative; boundary="%s"\n\n' "$alt"
    _emit_alt_parts "$alt" "$body" "$html" "$logo_cid"
    printf -- '--%s\n' "$rel"
    printf 'Content-Type: image/png\n'
    printf 'Content-Transfer-Encoding: base64\n'
    printf 'Content-ID: <%s>\n' "$logo_cid"
    printf 'Content-Disposition: inline; filename="vantage-point-logo.png"\n\n'
    _emit_base64_body < "$logo"
    printf -- '--%s--\n' "$rel"
  else
    printf 'Content-Type: multipart/alternative; boundary="%s"\n\n' "$alt"
    _emit_alt_parts "$alt" "$body" "$html" ""
  fi
}

# Print one utf-8 plain-text message to stdout (the no-renderer fallback). Declares
# utf-8 so the bullets/arrows/em-dashes don't get mangled.
# Args: <encoded-subject> <body-markdown-file> <recipient>.
_emit_plain() {
  local subject="$1" body="$2" to="$3"
  printf 'To: %s\n' "$to"
  printf 'Subject: %s\n' "$subject"
  printf 'MIME-Version: 1.0\n'
  printf 'Content-Type: text/plain; charset=utf-8\n'
  printf 'Content-Transfer-Encoding: 8bit\n\n'
  cat "$body"
}

# Send a Markdown body as a polished email to one or more recipients. Multipart/
# alternative (plain markdown + rendered HTML) when a renderer is available; otherwise
# a utf-8 plain-text message. When the caller sets VP_LOGO to a readable PNG (gated by
# output.email_images), the HTML copy carries that logo as a CID-embedded inline image
# (no external fetch). The body file is unchanged on disk. The caller sets the VP_*
# chrome (read by wrap_html via dynamic scope) and passes the raw subject, then one or
# more recipients. Each recipient gets its OWN message - a separate msmtp envelope
# whose only To: header is that one address - so a recipient never sees the others (no
# shared To:/Cc list). Returns the last nonzero msmtp status, if any.
send_email() {  # <subject> <body-markdown-file> <recipient>...
  local subject body="$2"
  subject="$(encode_header "$1")"   # RFC 2047 if it has non-ASCII chars
  shift 2                           # remaining args = recipients
  # Render the Markdown body once; every recipient gets identical content and only the
  # To: line differs. An empty result (no renderer / render failure) -> plain text.
  local html
  if ! html="$(render_md_to_html < "$body" 2>/dev/null)"; then
    html=""
  fi
  # Embed the logo only when an HTML part exists and VP_LOGO points to a readable file
  # (fail-safe: a missing/unreadable asset silently degrades to the no-image email).
  local logo="" logo_cid=""
  if [ -n "$html" ] && [ -n "${VP_LOGO:-}" ] && [ -r "${VP_LOGO:-}" ]; then
    logo="$VP_LOGO"; logo_cid="${VP_LOGO_CID:-vp-logo@vantagepoint}"
  fi
  local rc=0 r
  for r in "$@"; do
    if [ -n "$html" ]; then
      _emit_html "$subject" "$body" "$html" "$r" "$logo" "$logo_cid" | msmtp "$r" || rc=$?
    else
      _emit_plain "$subject" "$body" "$r" | msmtp "$r" || rc=$?
    fi
  done
  return "$rc"
}
