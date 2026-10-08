#!/bin/sh
# Shared runtime conformance, without any target's property framework.
# ref:DEC-local-ci-only ref:DEC-tests-cite-requirements
set -eu
cd "$(dirname "$0")/.."
beam_artifacts=.artifacts/beam-runtime
mkdir -p "$beam_artifacts"
mkdir -p "$beam_artifacts/priv"
cp runtime/lawspec_crypto_native.c "$beam_artifacts/priv/lawspec_crypto_native.c"
escript runtime/lawspec_crypto_build.escript "$beam_artifacts"
python3 tools/beam-crypto-build.py
stack --no-terminal run lawspec-dev -- beam-vectors "$beam_artifacts/scalars.json"
python3 tools/beam-values-reference.py "$beam_artifacts/values.json"
python3 tools/beam-model-reference.py "$beam_artifacts/models.json" "$beam_artifacts/model-parallel.json" "$beam_artifacts/model-histories.json"
python3 tools/beam-history-reference.py "$beam_artifacts/scenario-histories.json"
python3 tools/beam-scenario-reference.py "$beam_artifacts/scenario-schedules.json"
python3 tools/beam-network-reference.py "$beam_artifacts/network-frames.json" "$beam_artifacts/network-faults.json"
python3 tools/beam-channel-reference.py "$beam_artifacts/channel-states.json"
erlc -Werror -o "$beam_artifacts" runtime/lawspec_beam_*.erl test/fixtures/beam/*.erl
erl -noshell -pa "$beam_artifacts" -eval '
    lawspec_beam_scalar_tests:vectors(".artifacts/beam-runtime/scalars.json"),
    lawspec_beam_values_tests:vectors(".artifacts/beam-runtime/values.json"),
    lawspec_beam_model_tests:vectors(".artifacts/beam-runtime/models.json"),
    lawspec_beam_model_parallel_tests:vectors(".artifacts/beam-runtime/model-parallel.json"),
    lawspec_beam_model_parallel_tests:histories(".artifacts/beam-runtime/model-histories.json"),
    lawspec_beam_history_tests:vectors(".artifacts/beam-runtime/scenario-histories.json"),
    lawspec_beam_scenario_tests:vectors(".artifacts/beam-runtime/scenario-schedules.json"),
    lawspec_beam_wire_tests:vectors(".artifacts/beam-runtime/network-frames.json"),
    lawspec_beam_memory_network_tests:vectors(".artifacts/beam-runtime/network-faults.json"),
    lawspec_beam_channel_protocol_tests:vectors(".artifacts/beam-runtime/channel-states.json"),
    case eunit:test([lawspec_beam_scalar_tests, lawspec_beam_schema_tests,
            lawspec_beam_values_tests, lawspec_beam_runtime_tests, lawspec_beam_effects_tests,
            lawspec_beam_defaults_tests, lawspec_beam_crypto_tests, lawspec_beam_waits_tests,
            lawspec_beam_policy_tests, lawspec_beam_tasks_tests, lawspec_beam_attempts_tests,
            lawspec_beam_workflow_state_tests, lawspec_beam_workflow_tests,
            lawspec_beam_actors_tests, lawspec_beam_supervision_tests, lawspec_beam_model_tests, lawspec_beam_model_parallel_tests,
            lawspec_beam_history_tests, lawspec_beam_scenario_io_tests, lawspec_beam_scenario_tests,
            lawspec_beam_wire_tests, lawspec_beam_memory_network_tests,
            lawspec_beam_channel_protocol_tests, lawspec_beam_node_tests,
            lawspec_beam_endpoint_tests, lawspec_beam_scenario_network_tests, lawspec_beam_mailbox_tests,
            lawspec_beam_session_tests,
            lawspec_beam_gleam_tests], [verbose]) of
        ok -> halt(0);
        _ -> halt(1)
    end.'
