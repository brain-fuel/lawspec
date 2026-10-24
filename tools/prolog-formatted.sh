#!/bin/sh
# The Prolog target's formatted step: generated Prolog is in SWI-Prolog's
# conventional layout (every clause as portray_clause/2 prints it), and the
# Python files the Prolog backend writes (its runtimes, launcher, models,
# generator factories and unit bridges) are unchanged by the pinned ruff
# format. The Python target's own files are checked by its formatted step.
# Usage: tools/prolog-formatted.sh PYTHON DIRECTORY
# ref:DEC-readable-artifacts
set -u
python=$1
case $python in /*) ;; */*) python=$PWD/$python ;; esac
directory=$2
root=$(cd "$(dirname "$0")/.." && pwd)
status=0
swipl "$root/tools/prolog-layout.pl" -- "$directory" || status=1
host=$(cd "$directory" && { ls lawspec_test.py 2>/dev/null; find . -name 'lawspec_prolog*.py';
  grep -rl --include='*.py' -e '^# The Prolog bridge for ' . ; } | sort -u)
if [ -n "$host" ]; then
  (cd "$directory" && echo "$host" | xargs "$python" -m ruff format --check --diff --isolated --no-cache) || status=1
fi
exit $status
