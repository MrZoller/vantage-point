#!/usr/bin/env python3
"""Apply a non-blocking exclusive flock to an inherited file descriptor."""

import fcntl
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: flock-fd.py FD", file=sys.stderr)
        return 2
    try:
        fd = int(sys.argv[1])
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return 1
    except (OSError, ValueError) as exc:
        print(f"flock-fd.py: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
