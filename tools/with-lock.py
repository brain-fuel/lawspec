"""Run a command holding an exclusive lock on a file.

    python3 tools/with-lock.py <lock file> <command> [argument...]

The lock is an flock on a descriptor the command inherits: it lasts as long
as the command, and the system releases it when the command ends, however it
ends. A second caller waits, and says so once.
"""

import fcntl
import os
import sys


def main() -> None:
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    path, command = sys.argv[1], sys.argv[2:]
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print(f"Waiting for the holder of {path}...", file=sys.stderr, flush=True)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
    os.set_inheritable(descriptor, True)
    os.execvp(command[0], command)


if __name__ == "__main__":
    main()
