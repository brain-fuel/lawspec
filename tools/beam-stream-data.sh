#!/bin/sh
# Exercise the pinned StreamData generator and shrinker directly.
# ref:DEC-native-property-frameworks ref:DEC-tests-cite-requirements
set -eu
cd "$(dirname "$0")/.."
stream_ebin=.integration/elixir/_build/test/lib/stream_data/ebin
if [ ! -f "$stream_ebin/Elixir.StreamData.beam" ]; then
    node tools/bootstrap-integration.mjs elixir
fi
stream_artifacts=.artifacts/beam-stream-data
mkdir -p "$stream_artifacts"
erlc -Werror -o "$stream_artifacts" runtime/lawspec_beam_*.erl test/fixtures/beam/lawspec_beam_index_tests.erl test/fixtures/beam/lawspec_beam_native_generator_tests.erl
elixir -pa "$stream_ebin" -pa "$stream_artifacts" -r runtime/lawspec_beam_stream_data.ex test/fixtures/beam/stream_data_test.exs
