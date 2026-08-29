# Worklog

Append-only. One entry per task cycle or session, one bullet stamped
`- YYYY-MM-DD HH:MM UTC - ` (date and 24-hour clock time, UTC), then task id,
what happened, decisions and why, verification commands run, follow-ups.
Newest at the bottom.

---

- 2026-08-29 02:02 UTC - Plan approved after verifying the document and its required sections; `spec_approved` prerequisite satisfied, phase advanced to build with runnable tasks available; verification: inspected `.factory/plan.md` and `.factory/state.json`; next: factory selects T1.
- 2026-08-29 02:30 UTC - T1 shipped as PR #80: server fixtures now bind OS-assigned ports, publish PID-tied readiness, and terminate then `wait`; verification: `shellcheck bin/*.sh tests/run.sh && python3 -m py_compile bin/*.py && bash tests/run.sh` (917 passed, 0 failed), plus two concurrent `bash tests/run.sh` runs (both 917 passed, 0 failed); panel: 1 round; findings 0 blocking / 0 minor / 0 invalid; 0 fixed; shipped standard (planned standard); next: shepherd PR #80.
