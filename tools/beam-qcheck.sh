#!/bin/sh
# The pinned Gleam framework is used directly, including its shrink trees.
# ref:DEC-native-property-frameworks ref:DEC-tests-cite-requirements
set -eu
cd "$(dirname "$0")/.."
qcheck_build=.integration/gleam/build/dev/erlang
if [ ! -f "$qcheck_build/qcheck/ebin/qcheck.beam" ]; then
    node tools/bootstrap-integration.mjs gleam
fi
qcheck_artifacts=.artifacts/beam-qcheck
mkdir -p "$qcheck_artifacts"
erlc -Werror -o "$qcheck_artifacts" runtime/lawspec_beam_*.erl test/fixtures/beam/lawspec_beam_qcheck_tests.erl test/fixtures/beam/lawspec_beam_index_tests.erl test/fixtures/beam/lawspec_beam_native_generator_tests.erl
erl -noshell -pa "$qcheck_artifacts" -pa "$qcheck_build"/*/ebin -eval '
    case eunit:test(lawspec_beam_qcheck_tests, [verbose]) of
        ok -> halt(0);
        _ -> halt(1)
    end.'
