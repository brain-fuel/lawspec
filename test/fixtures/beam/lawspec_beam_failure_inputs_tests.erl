%% @doc Persist real native shrink results and replay shared wire values.
%% ref:REQ-harness-units ref:DEC-shrink-within-domain ref:DEC-tests-cite-requirements
-module(lawspec_beam_failure_inputs_tests).
-include_lib("eunit/include/eunit.hrl").
-export([tests/1, run/1]).

tests(F) -> [{Name, fun() -> with_directory(Test) end} || {Name, Test} <- [
    {"keeps the final native shrink and replays it before a repaired run", fun(D) -> shrunk(F, D) end},
    {"wire inputs preserve exact integers, data, text and bytes", fun wire/1},
    {"different law identities cannot overwrite each other's inputs", fun identities/1},
    {"incompatible saved inputs never reach an adapter", fun incompatible/1},
    {"current input refinements can reject an obsolete counterexample", fun refinements/1},
    {"targeted search saves its actual failing inputs", fun targeted/1},
    {"concurrent saves leave one complete record and no temporary files", fun concurrent/1},
    {"a missing failure directory leaves native exceptions unchanged", fun disabled/1}
]].

run(F) -> lists:foreach(fun({_, Test}) -> Test() end, tests(F)), ok.

with_directory(Test) ->
    Root = case os:getenv("TMPDIR") of false -> "/tmp"; Directory -> Directory end,
    Directory1 = filename:join(Root, "lawspec-beam-inputs-" ++ os:getpid() ++ "-" ++ integer_to_list(erlang:unique_integer([positive]))),
    Previous = [{Key, os:getenv(Key)} || Key <- ["LAWSPEC_FAILURES", "LAWSPEC_SEED", "LAWSPEC_STATS"]],
    ok = file:make_dir(Directory1),
    true = os:putenv("LAWSPEC_FAILURES", Directory1),
    true = os:putenv("LAWSPEC_SEED", "42"),
    os:unsetenv("LAWSPEC_STATS"),
    try Test(Directory1)
    after
        lists:foreach(fun({Key, false}) -> os:unsetenv(Key); ({Key, Value}) -> os:putenv(Key, Value) end, Previous),
        file:del_dir_r(Directory1)
    end.

descriptor() -> [<<"(int Int32 5 1000)">>].

shrunk(F, Directory) ->
    Law = <<"example.replay::smallest">>,
    Ds = descriptor(),
    Generator = F:fixed_list([F:integer(5, 1000)]),
    Check = fun(Values) -> lawspec_beam_search:guard(Law, Ds, Values, fun() -> false end) end,
    Failure = try F:check(Law, F:forall(Generator, Check),
        [{numtests, 20}, {max_shrinks, 1000}, {constraint_tries, 100}]), passed
        catch error:Cause -> Cause end,
    ?assertNotEqual(passed, Failure),
    [File] = files(Directory),
    {ok, Original} = file:read_file(File),
    ?assertEqual(#{<<"law">> => Law, <<"inputs">> => [<<"0a">>]}, json:decode(Original)),
    true = os:putenv("LAWSPEC_SEED", "987654"),
    ?assertError({still_broken, 5}, lawspec_beam_search:replay(Law, Ds, fun([N]) -> error({still_broken, N}) end)),
    ?assertEqual({ok, Original}, file:read_file(File)),
    ?assertError({lawspec, {replay_failed, Law}}, lawspec_beam_search:replay(Law, Ds, fun(_) -> false end)),
    ?assertEqual({ok, Original}, file:read_file(File)),
    put(replayed, []),
    ?assertEqual(ok, lawspec_beam_search:replay(Law, Ds, fun(Values) -> put(replayed, Values), true end)),
    ?assertEqual([5], erase(replayed)),
    ?assertEqual([], files(Directory)),
    ?assertEqual(ok, lawspec_beam_search:replay(Law, Ds, fun(_) -> error(already_cleared) end)).

wire(Directory) ->
    Law = <<"example.replay::wire">>,
    Ds = [<<"(int Integer _ _)">>, <<"(list (int Int8 -128 127))">>,
        <<"(data Pair (ctor \"example.Pair::Pair\" (int Integer _ _) (text))) (ref Pair)">>,
        <<"(bytes)">>, <<"(maybe (bool))">>, <<"(either (unit) (text))">>],
    Values = [-(1 bsl 120), [-128, 0, 127], {ls_data, <<"example.Pair::Pair">>, [1 bsl 100, <<"hello ", 16#03bb/utf8, 0>>]},
        <<0, 128, 255>>, {ls_data, <<"Maybe::Just">>, [true]}, {ls_data, <<"Either::Left">>, [ls_unit]}],
    ok = lawspec_beam_search:remember(Law, Ds, Values),
    ok = lawspec_beam_search:replay(Law, Ds, fun(Actual) -> ?assertEqual(Values, Actual), true end),
    ?assertEqual([], files(Directory)).

identities(Directory) ->
    A = <<"unit::same law">>, B = <<"unit::same-law">>, Ds = descriptor(),
    ok = lawspec_beam_search:remember(A, Ds, [5]),
    ok = lawspec_beam_search:remember(B, Ds, [6]),
    ?assertEqual(2, length(files(Directory))),
    ok = lawspec_beam_search:replay(A, Ds, fun(V) -> ?assertEqual([5], V), true end),
    ?assertEqual(1, length(files(Directory))),
    ok = lawspec_beam_search:replay(B, Ds, fun(V) -> ?assertEqual([6], V), true end).

incompatible(Directory) ->
    Law = <<"unit::stale">>, Ds = descriptor(),
    lists:foreach(fun(Bytes) ->
        ok = lawspec_beam_search:remember(Law, Ds, [5]),
        [File] = files(Directory),
        ok = file:write_file(File, Bytes),
        ok = lawspec_beam_search:replay(Law, Ds, fun(_) -> error(incompatible_adapter_call) end),
        ?assertEqual([], files(Directory))
    end, [<<"broken JSON">>, json:encode(#{law => <<"different law">>, inputs => [<<"0a">>]}),
        json:encode(#{law => Law, inputs => []}), json:encode(#{law => Law, inputs => [<<"0a">>, <<"0c">>]}),
        json:encode(#{law => Law, inputs => [<<"0a00">>]}), json:encode(#{law => Law, inputs => [<<"zz">>]}),
        json:encode(#{law => Law, inputs => [<<"00">>]})]).

refinements(Directory) ->
    Law = <<"unit::dependent">>, Ds = descriptor() ++ descriptor(),
    ok = lawspec_beam_search:remember(Law, Ds, [5, 5]),
    ok = lawspec_beam_search:replay(Law, Ds, fun([X, Y]) ->
        case Y > X of true -> error(invalid_adapter_call); false -> none end
    end),
    ?assertEqual([], files(Directory)).

targeted(Directory) ->
    Law = <<"unit::targeted">>, Ds = descriptor(),
    Failure = try lawspec_beam_search:climb(Law, Ds, fun([V]) -> error({target_bug, V}) end), passed
        catch error:Cause -> Cause end,
    ?assertMatch({lawspec, {target_failed, Law, {seed, 42}, {inputs, [_]}, {error, {target_bug, _}}}}, Failure),
    {lawspec, {target_failed, _, _, _, {error, {target_bug, Expected}}}} = Failure,
    ?assertEqual(1, length(files(Directory))),
    ok = lawspec_beam_search:replay(Law, Ds, fun(V) -> ?assertEqual([Expected], V), true end).

concurrent(Directory) ->
    Law = <<"unit::concurrent">>, Ds = descriptor(),
    Workers = [spawn_monitor(fun() -> lawspec_beam_search:remember(Law, Ds, [N]) end) || N <- lists:seq(5, 20)],
    lists:foreach(fun({Pid, Ref}) -> receive {'DOWN', Ref, process, Pid, Result} -> ?assertEqual(normal, Result)
        after 5000 -> error(save_timeout) end end, Workers),
    {ok, Names} = file:list_dir(filename:join(Directory, "inputs")),
    ?assertEqual(1, length(Names)),
    ok = lawspec_beam_search:replay(Law, Ds, fun([N]) -> N >= 5 andalso N =< 20 end).

disabled(_) ->
    os:unsetenv("LAWSPEC_FAILURES"),
    ?assertEqual(ok, lawspec_beam_search:remember(<<"disabled">>, [invalid_descriptor], [])),
    ?assertError(original, lawspec_beam_search:guard(<<"disabled">>, [], [], fun() -> error(original) end)),
    ?assertEqual(false, lawspec_beam_search:guard(<<"disabled">>, [], [], fun() -> false end)).

files(Directory) -> filelib:wildcard(filename:join([Directory, "inputs", "*.json"])).
