#!/bin/sh
# Run the compiler's Hspec suite, or the part of it the arguments select,
# from the test executable the CI build step built. Running the executable
# rather than `stack test` lets several parts run at once, and does not
# reconfigure the package. ref:DEC-local-ci-only ref:DEC-parallel-ci
set -eu
cd "$(dirname "$0")/.."
exec "$(stack --no-terminal path --dist-dir)/build/lawspec-test/lawspec-test" --format=specdoc --no-color "$@"
