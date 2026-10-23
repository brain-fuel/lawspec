#!/bin/sh
# The Prolog target's formatted step: generated Prolog is in SWI-Prolog's
# conventional layout (every clause as portray_clause/2 prints it), and the
# Python host files are unchanged by the pinned ruff format.
# Usage: tools/prolog-formatted.sh PYTHON DIRECTORY
# ref:DEC-readable-artifacts
set -u
python=$1
directory=$2
root=$(cd "$(dirname "$0")/.." && pwd)
status=0
swipl "$root/tools/prolog-layout.pl" -- "$directory" || status=1
"$python" -m ruff format --check --diff --isolated --no-cache "$directory" || status=1
exit $status
