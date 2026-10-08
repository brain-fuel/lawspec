%% @doc Native callers get the same checked definitions as generated laws.
%% ref:DEC-total-definitions ref:DEC-acceptance-with-mutants
-module(public_api_tests).
-include_lib("eunit/include/eunit.hrl").

checked_integer_api_test() ->
    ?assertEqual(127, example_refined_definitions_definitions:increment(126)),
    ?assertError({lawspec, {_, {contract_failed, <<"precondition">>}}},
        example_refined_definitions_definitions:increment(127)),
    ?assertError({lawspec, {integer_out_of_range, <<"Int8">>}},
        example_refined_definitions_definitions:increment(128)).

native_tuple_api_test() ->
    ?assertEqual({pair, 2, true}, example_data_types_definitions:positive_pair(2)),
    ?assertEqual(lawspec_beam_scalar:ratio(1, 2),
        example_data_types_definitions:reciprocal_first({pair, 2, true})),
    ?assertError({lawspec, {_, {contract_failed, <<"precondition">>}}},
        example_data_types_definitions:reciprocal_first({pair, 0, true})).

short_circuit_api_test() ->
    ?assertEqual(false, example_total_functions_definitions:guarded_narrow(127)),
    ?assertEqual(true, example_total_functions_definitions:guarded_narrow(126)).
