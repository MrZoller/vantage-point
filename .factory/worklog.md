# Worklog

Append-only. One entry per task cycle or session, one bullet stamped
`- YYYY-MM-DD HH:MM UTC - ` (date and 24-hour clock time, UTC), then task id,
what happened, decisions and why, verification commands run, follow-ups.
Newest at the bottom.

---

- 2026-08-29 02:02 UTC - Plan approved after verifying the document and its required sections; `spec_approved` prerequisite satisfied, phase advanced to build with runnable tasks available; verification: inspected `.factory/plan.md` and `.factory/state.json`; next: factory selects T1.
- 2026-08-29 02:30 UTC - T1 shipped as PR #80: server fixtures now bind OS-assigned ports, publish PID-tied readiness, and terminate then `wait`; verification: `shellcheck bin/*.sh tests/run.sh && python3 -m py_compile bin/*.py && bash tests/run.sh` (917 passed, 0 failed), plus two concurrent `bash tests/run.sh` runs (both 917 passed, 0 failed); panel: 1 round; findings 0 blocking / 0 minor / 0 invalid; 0 fixed; shipped standard (planned standard); next: shepherd PR #80.
- 2026-08-29 02:32 UTC - T1 shepherd pass on PR #80 verified head `09dd44a6ec0e10b80c7941aaac72b6e302fae1a9` is mergeable and current with no holds, labels, review threads, or Claude workflow configured; waiting on CI run 33229120008 (Ubuntu passed, macOS in progress) and Codex, whose in-flight eye reaction is not a verdict; no nudge or code change; next: a later shepherd pass rechecks CI and Codex.
