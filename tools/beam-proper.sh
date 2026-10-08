#!/bin/sh
# Exercise the pinned native property framework, including its shrinker.
# ref:DEC-native-property-frameworks ref:DEC-tests-cite-requirements
set -eu
cd "$(dirname "$0")/.."
proper_ebin=.integration/erlang/_build/default/lib/proper/ebin
if [ ! -f "$proper_ebin/proper.beam" ]; then
    node tools/bootstrap-integration.mjs erlang
fi
proper_artifacts=.artifacts/beam-proper
mkdir -p "$proper_artifacts"
erlc -Werror -o "$proper_artifacts" runtime/lawspec_beam_*.erl test/fixtures/beam/lawspec_beam_proper_tests.erl
erl -noshell -pa "$proper_artifacts" -pa "$proper_ebin" -eval '
    case eunit:test(lawspec_beam_proper_tests, [verbose]) of
        ok -> halt(0);
        _ -> halt(1)
    end.'
