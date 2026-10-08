#!/bin/sh
# Shared runtime conformance, without any target's property framework.
# ref:DEC-local-ci-only ref:DEC-tests-cite-requirements
set -eu
cd "$(dirname "$0")/.."
beam_artifacts=.artifacts/beam-runtime
mkdir -p "$beam_artifacts"
stack --no-terminal run lawspec-dev -- beam-vectors "$beam_artifacts/scalars.json"
python3 tools/beam-values-reference.py "$beam_artifacts/values.json"
erlc -Werror -o "$beam_artifacts" runtime/lawspec_beam_*.erl test/fixtures/beam/*.erl
erl -noshell -pa "$beam_artifacts" -eval '
    lawspec_beam_scalar_tests:vectors(".artifacts/beam-runtime/scalars.json"),
    lawspec_beam_values_tests:vectors(".artifacts/beam-runtime/values.json"),
    case eunit:test([lawspec_beam_scalar_tests, lawspec_beam_schema_tests,
            lawspec_beam_values_tests, lawspec_beam_runtime_tests, lawspec_beam_effects_tests,
            lawspec_beam_defaults_tests, lawspec_beam_gleam_tests], [verbose]) of
        ok -> halt(0);
        _ -> halt(1)
    end.'
