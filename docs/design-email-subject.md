# Design: thread-friendly email subject

*Status: proposed (backlog — not started). Companion to the backlog entry in
[`roadmap.md`](roadmap.md). Deliberately the smallest design in this folder —
the feature is one config knob and one substitution.*

## Problem

Every monitor report goes out as
`[Vantage Point: <subject.name>] <mode> <date>` (`email_report()` in
`bin/monitor.sh`). The stable leading prefix makes Gmail's conversation view
fold the reports into one ever-growing thread: each day's brief lands as
"message 47 of a conversation" instead of a fresh item at the top of the
inbox, the unread state gets swallowed by the thread, and the carefully built
preheader/bottom-line (Phase 5) is never seen. For a product whose entire
delivery promise is "a brief someone looks forward to", being auto-buried by
the mail client is a real defect — and "just turn off conversation view" is a
workaround the recipient's teammates (Phase 17 fan-out) can't be asked to
share.

Different readers want different fixes (date-first, market-first, no prefix at
all, or the status quo — some people *like* one thread per agent), so this is
a formatting preference, not a behavior to hardcode: one template knob.

## Design

### One knob: `output.email_subject`

A template string with three tokens, substituted in shell:

| Token | Value |
|---|---|
| `{name}` | `subject.name` (already in `$SUBJECT_NAME`) |
| `{mode}` | `daily` / `weekly` |
| `{date}` | `$TODAY` (`YYYY-MM-DD`) |

```yaml
output:
  email_subject: "{name} — {mode} {date}"     # date/market first: no shared
                                              # prefix, so Gmail starts a new
                                              # conversation per report
```

Absent/blank → **today's format byte-for-byte** (`[Vantage Point: {name}]
{mode} {date}`, or `[Vantage Point] {mode} {date}` when `subject.name` is
unset) — the same back-compat guarantee every knob in this project gives.
Because `{date}` differs per run, any template that *leads* with `{name}` or
`{date}` instead of a constant bracket-prefix threads separately in practice;
the docs say that plainly rather than promising specific Gmail behavior.

### Scope: the monitor's report mail and webhook heading, in lockstep

The webhook payload's `title` uses the identical string today (built twice,
once in `email_report()` and once inline for `wh_heading`); consolidate both
into one `report_subject()` helper in `bin/monitor.sh` that applies the
template, so the inbox and the Slack channel always name a report the same
way (and the duplicated construction goes away).

**Bootstrap's draft-review email keeps its fixed subject**
(`[Vantage Point: <name>] profile draft ready for review`, `bin/bootstrap.sh`)
on purpose: draft → re-bootstrap → approval discussion *belongs* in one
thread, and the template's `{mode}`/`{date}` tokens don't apply to it.

### Implementation notes

- Read via `cfg_get_text output email_subject` (handles YAML quoting for the
  `&`/`#`/quote cases a marketing-ish name will hit).
- Substitution is plain bash parameter expansion
  (`s=${s//'{name}'/$SUBJECT_NAME}` etc.) — no `eval`, no printf-format
  injection surface. Unknown `{tokens}` pass through literally with a one-time
  stderr note (a typo'd token visibly survives into one subject line, which is
  exactly how the user finds the typo).
- Non-ASCII in the template is fine: it arrives from config (the
  shell-scripts-stay-ASCII rule constrains the repo's files, not user
  values), and `send_email` already RFC-2047-encodes the subject via
  `encode_header`.
- An `email_subject` that substitutes to empty falls back to the default
  (an empty Subject: is never what anyone meant).

### Failure modes

| Failure | Behavior |
|---|---|
| knob absent/blank (default) | today's subject, byte-for-byte; no note |
| template has no tokens | a constant subject every run — allowed (it's the status-quo threading behavior, chosen explicitly) |
| unknown token | passes through literally + a stderr note |
| substitutes to empty | default subject + a stderr note |
| `subject.name` unset with `{name}` in the template | substitutes to nothing; the empty-collapse rule above catches the degenerate case |

## Tests (`tests/run.sh`; msmtp is stubbed)

1. **Default unchanged:** no knob → the msmtp capture's `Subject:` and the
   webhook payload `title` equal today's exact strings (with and without
   `subject.name` set).
2. **Template applied:** `email_subject: "{name} — {mode} {date}"` → both
   carriers show the substituted string (same string in both — the lockstep
   assertion).
3. **Quoting:** a `subject.name` containing `&` and quotes round-trips into
   the Subject header.
4. **Unknown token** `{foo}` survives literally; stderr carries the note.
5. **Empty result** falls back to the default.
6. **Bootstrap unaffected:** the draft-review mail's subject is unchanged
   regardless of the knob.
7. `shellcheck` on `bin/monitor.sh`.

## Cost

None — string formatting on an existing code path.

## Out of scope / v2 ideas

- **A per-run token** (`{id}`, short run hash) for forcing unthreadable
  subjects even with a constant template — add only if someone actually asks;
  `{date}` already varies daily.
- **`References:`/`In-Reply-To:` header control** — real thread *steering*
  (e.g. weekly digests threading under each other deliberately) is a
  different, bigger feature; subjects are as far as this one goes.
- **Templating the webhook payload fields beyond `title`** — the JSON
  payload is for machines; receivers format their own display.
