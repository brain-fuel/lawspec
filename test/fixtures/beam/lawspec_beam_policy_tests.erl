%% @doc Retry arithmetic agrees with the shared workflow policy contract.
%% ref:DEC-tests-cite-requirements ref:DEC-typed-core-boundary
-module(lawspec_beam_policy_tests).
-include_lib("eunit/include/eunit.hrl").

retry_sequences_test() ->
    Cases = [{immediate, [0,0,0,0,0]}, {{fixed, 7}, [7,7,7,7,7]},
        {{linear, 7, 3}, [7,10,13,16,19]},
        {{exponential, 7, 3, none}, [7,21,63,189,567]},
        {{exponential, 7, 3, 100}, [7,21,63,100,100]},
        {{fibonacci, 7}, [7,7,14,21,35]}],
    lists:foreach(fun({Strategy, Expected}) ->
        ?assertEqual(Expected, [lawspec_beam_policy:retry_delay(Strategy, N) || N <- lists:seq(2, 6)])
    end, Cases).

unbounded_integer_delays_test() ->
    ?assertEqual(1 bsl 200, lawspec_beam_policy:retry_delay({exponential, 1, 2, none}, 202)),
    ?assertEqual(1000, lawspec_beam_policy:retry_delay({exponential, 1, 2, 1000}, 202)).

jitter_uses_the_portable_stream_test() ->
    {Draw, Next} = lawspec_beam_random:next(0),
    ?assertEqual(16294208416658607535, Draw),
    ?assertEqual({123, 0}, lawspec_beam_policy:jitter(none, 123, 0, 4, 0)),
    ?assertEqual({Draw rem 124, Next}, lawspec_beam_policy:jitter(full, 123, 0, 4, 0)),
    ?assertEqual({61 + Draw rem 63, Next}, lawspec_beam_policy:jitter(equal, 123, 0, 4, 0)),
    ?assertEqual({min(123, 4 + Draw rem 297), Next}, lawspec_beam_policy:jitter(decorrelated, 123, 100, 4, 0)),
    ?assertEqual({4, Next}, lawspec_beam_policy:jitter(decorrelated, 123, 0, 4, 0)),
    ?assertEqual({0, Next}, lawspec_beam_policy:jitter(full, 0, 0, 0, 0)).

retry_decisions_and_policy_failures_test() ->
    ?assertEqual(stop, lawspec_beam_policy:retry_decision({ls_data, <<"lawspec.time::type::RetryDecision::Stop">>, []})),
    ?assertEqual({wait, 123}, lawspec_beam_policy:retry_decision(
        {ls_data, <<"lawspec.time::type::RetryDecision::RetryAfter">>,
            [{ls_data, <<"lawspec.time::type::Duration::Duration">>, [123]}]})),
    lists:foreach(fun(Kind) ->
        Failure = lawspec_beam_policy:stage_failure(Kind),
        ?assert(lawspec_beam_policy:failed(Failure)),
        ?assertEqual({ls_data, <<"Either::Left">>,
            [{ls_data, <<"lawspec.resilience::type::StageFailure::", Kind/binary>>, []}]}, Failure)
    end, [<<"TimedOut">>, <<"RateLimited">>, <<"CircuitOpen">>, <<"Saturated">>]),
    ?assertNot(lawspec_beam_policy:failed({ls_data, <<"Either::Right">>, [42]})).
