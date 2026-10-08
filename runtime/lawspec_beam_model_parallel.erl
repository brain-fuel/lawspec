%% @doc Concurrent model histories, generated from a valid sequential prefix.
%% Every branch interleaving must be allowed by the reference. Actual calls
%% run in owned BEAM workers; a shared atomic counter records their intervals.
%% ref:DEC-stateful-models-linearizability ref:herlihy-wing-linearizability
%% ref:wing-gong-linearizability ref:DEC-portable-seeded-generation
-module(lawspec_beam_model_parallel).
-export([check/1, check/2, generate/5, allowed/2, execute/3, consistent/7,
    shrink/6, candidates/2, describe/2]).

generate(Model, Random, Size, Threads, BranchLength) ->
    {Length, R1} = lawspec_beam_random:below(4, Random),
    {Prefix = {Args, _}, R2} = lawspec_beam_model:generate(Model, R1, Length, Size, false),
    case lawspec_beam_model:simulate(Model, Prefix) of
        invalid -> {{Prefix, lists:duplicate(Threads, [])}, R2};
        {ok, States} ->
            {Branches, R3} = lawspec_beam_model:with_context(Model, Args, fun(Context) ->
                lists:mapfoldl(fun(_, R) ->
                    {N, Next} = lawspec_beam_random:below(BranchLength, R),
                    generate_branch(Model, Context, Next, Size, N + 1, lists:last(States), [])
                end, R2, lists:seq(1, Threads))
            end),
            {trim(Model, {Prefix, Branches}), R3}
    end.
generate_branch(_, _, Random, _, 0, _, Steps) -> {lists:reverse(Steps), Random};
generate_branch(#{commands := Commands}, _, Random, _, _, _, Steps) when tuple_size(Commands) =:= 0 ->
    {lists:reverse(Steps), Random};
generate_branch(Model, Context, Random, Size, Remaining, State, Steps) ->
    {Index, R1} = lawspec_beam_random:below(tuple_size(maps:get(commands, Model)), Random),
    Command = lawspec_beam_model:command(Model, Index),
    {Args, R2} = lists:mapfoldl(fun(D, R) -> lawspec_beam_values:generate(D, maps:get(table, Model), R, Size) end,
        R1, maps:get(arguments, Command)),
    case lawspec_beam_model:step(Command, Context, Args, State) of
        invalid -> generate_branch(Model, Context, R2, Size, Remaining - 1, State, Steps);
        {ok, Next, _} -> generate_branch(Model, Context, R2, Size, Remaining - 1, Next, [{Index, Args} | Steps])
    end.
trim(Model, Case = {Prefix, Branches}) ->
    case allowed(Model, Case) of
        true -> Case;
        false ->
            Length = lists:max([length(B) || B <- Branches]),
            %% First longest branch, as on every other target.
            [I | _] = [K || {K, B} <- numbered(Branches), length(B) =:= Length],
            trim(Model, {Prefix, replace(Branches, I, lists:sublist(lists:nth(I + 1, Branches), Length - 1))})
    end.

allowed(Model, {Prefix = {Args, _}, Branches}) ->
    case lawspec_beam_model:simulate(Model, Prefix) of
        invalid -> false;
        {ok, States} -> lawspec_beam_model:with_context(Model, Args, fun(Context) ->
            {Answer, _} = all_orders(Model, Context, tuple_branches(Branches), positions(Branches), lists:last(States), #{}),
            Answer
        end)
    end.
all_orders(Model, Context, Branches, Positions, State, Seen) ->
    Key = {Positions, State},
    case maps:is_key(Key, Seen) of
        true -> {true, Seen};
        false -> all_next(Model, Context, Branches, Positions, State, pending(Branches, Positions), Seen#{Key => true})
    end.
all_next(_, _, _, _, _, [], Seen) -> {true, Seen};
all_next(Model, Context, Branches, Positions, State, [{I, {Index, Args}} | Rest], Seen) ->
    case lawspec_beam_model:step(lawspec_beam_model:command(Model, Index), Context, Args, State) of
        invalid -> {false, Seen};
        {ok, Next, _} -> case all_orders(Model, Context, Branches, advance(Positions, I), Next, Seen) of
            {false, S} -> {false, S};
            {true, S} -> all_next(Model, Context, Branches, Positions, State, Rest, S)
        end
    end.

execute(Model, {{StartArgs, Steps}, Branches}, Shake) ->
    try lawspec_beam_model:with_system(Model, StartArgs, length(Steps), fun(Context, System, Expected) ->
        FinalPrefix = prefix(Model, Context, Steps, System, Expected),
        Clock = atomics:new(1, []),
        History = lawspec_beam_runtime:concurrently([
            fun() -> run_branch(Model, Context, System, Clock, Branch,
                lawspec_beam_random:seed(Shake bxor ((I + 1) * 16#9e3779b97f4a7c15))) end
            || {I, Branch} <- numbered(Branches)]),
        case [Error || Events <- History, {_, _, {error, _} = Error} <- Events] of
            [{error, Error} | _] -> {error, Error};
            [] ->
                Values = [[{A, B, V} || {A, B, {ok, V}} <- Events] || Events <- History],
                Final = case maps:get(abstract, Model) of
                    none -> none;
                    Abstract -> {some, lawspec_beam_model:callback(Abstract, Context, [system_state(Model, System)])}
                end,
                case consistent(Model, Context, Branches, Values, FinalPrefix, Final, System) of
                    true -> ok;
                    false -> {error, #{reason => no_consistent_order, history => Values}}
                end
        end
    end)
    catch Class:Reason:Stack -> {error, #{reason => {raised, Class, Reason}, stack => Stack}} end.
prefix(Model, Context, [], System, Expected) ->
    lawspec_beam_model:check_state(Model, Context, System, Expected), Expected;
prefix(Model, Context, [{I, Args} | Steps], System, Expected) ->
    lawspec_beam_model:check_state(Model, Context, System, Expected),
    Command = lawspec_beam_model:command(Model, I),
    {ok, Next, Wanted} = lawspec_beam_model:step(Command, Context, Args, Expected),
    {Result, System} = lawspec_beam_model:invoke(Model, Context, Command, Args, System),
    case maps:get(unit, Command) orelse lawspec_beam_scalar:equal(Result, Wanted) of
        false -> error({lawspec, {model_prefix_returned, Result, Wanted}});
        true -> prefix(Model, Context, Steps, System, Next)
    end.
system_state(#{actor := true}, System) -> lawspec_beam_actors:state(System);
system_state(_, System) -> System.
run_branch(Model, Context, System, Clock, Branch, Random) ->
    {History, _} = lists:mapfoldl(fun({I, Args}, R) ->
        Command = lawspec_beam_model:command(Model, I),
        R1 = perturb(R), Called = atomics:add_get(Clock, 1, 1),
        Result = try
            {Value, System} = lawspec_beam_model:invoke(Model, Context, Command, Args, System), {ok, Value}
        catch Class:Reason:Stack -> {error, #{command => maps:get(name, Command),
            reason => {raised, Class, Reason}, stack => Stack}} end,
        Returned = atomics:add_get(Clock, 1, 1), R2 = perturb(R1),
        {{Called, Returned, Result}, R2}
    end, Random, Branch), History.
perturb(Random) ->
    {Choice, Next} = lawspec_beam_random:below(4, Random),
    case Choice of
        0 -> ok;
        1 -> erlang:yield();
        %% Native BEAM timers round the portable sub-millisecond sleeps up.
        _ -> receive after 1 -> ok end
    end,
    Next.

%% Search all orders consistent with process order and (for linearizability)
%% real time. Memoization is on complete logical terms and branch positions,
%% not rendered strings, so distinct states cannot alias through printing.
consistent(Model, Context, Branches, History, Expected, Final, System) ->
    Finish = fun(State) ->
        try
            Equal = case Final of none -> true; {some, Actual} -> lawspec_beam_scalar:equal(Actual, State) end,
            case Equal of false -> false; true ->
                lawspec_beam_model:check_state(Model#{abstract := none}, Context, System, State), true end
        catch _:_ -> false end
    end,
    case maps:get(consistency, Model) of
        <<"causal">> -> causal(Model, Context, Branches, History, Expected, System);
        _ ->
            %% Linearizability composes over independent keys. Sequential and
            %% eventual orders still need each caller's cross-key ordering;
            %% partitioning those histories can hide an impossible cycle.
            CanPartition = maps:get(consistency, Model) =:= <<"linearizable">> andalso
                maps:get(per_key, Model) andalso lists:all(fun({I, _}) ->
                maps:get(key, lawspec_beam_model:command(Model, I)) =/= none end, lists:append(Branches)),
            case CanPartition of
                false -> find_order(Model, Context, Branches, History, Expected, Finish) =/= false;
                true -> by_key(Model, Context, Branches, History, Expected, Finish)
            end
    end.
find_order(Model, Context, Branches, History, Expected, Finish) ->
    {Result, _} = visit(Model, Context, tuple_branches(Branches), tuple_branches(History),
        positions(Branches), Expected, Finish, #{}), Result.
visit(Model, Context, Branches, History, Positions, State, Finish, Seen) ->
    Key = {Positions, State},
    case maps:is_key(Key, Seen) of
        true -> {false, Seen};
        false ->
            Updated = Seen#{Key => true},
            case pending(Branches, Positions) of
                [] -> {case Finish(State) of true -> {ok, State}; false -> false end, Updated};
                Next -> visit_next(Model, Context, Branches, History, Positions, State, Finish, Next, Updated)
            end
    end.
visit_next(_, _, _, _, _, _, _, [], Seen) -> {false, Seen};
visit_next(Model, Context, Branches, History, Positions, State, Finish, [{I, {Index, Args}} | Rest], Seen) ->
    {Called, _, Result} = event(History, Positions, I),
    Linear = maps:get(consistency, Model) =:= <<"linearizable">>,
    Blocked = Linear andalso lists:any(fun({J, _}) ->
        {_, Returned, _} = event(History, Positions, J), J =/= I andalso Returned < Called
    end, pending(Branches, Positions)),
    Command = lawspec_beam_model:command(Model, Index),
    Attempt = case Blocked of true -> invalid; false -> lawspec_beam_model:step(Command, Context, Args, State) end,
    NextSearch = case Attempt of
        {ok, Next, Wanted} ->
            Ignore = maps:get(consistency, Model) =:= <<"eventual">> orelse maps:get(unit, Command),
            case Ignore orelse lawspec_beam_scalar:equal(Result, Wanted) of
                true -> visit(Model, Context, Branches, History, advance(Positions, I), Next, Finish, Seen);
                false -> {false, Seen}
            end;
        invalid -> {false, Seen}
    end,
    case NextSearch of
        {{ok, _}, _} = Found -> Found;
        {false, S} -> visit_next(Model, Context, Branches, History, Positions, State, Finish, Rest, S)
    end.
event(History, Positions, I) -> element(element(I, Positions) + 1, element(I, History)).

%% With no messages between these branches, a causal view contains that
%% caller's own operations. Scenarios supply their message dependencies to
%% their separate history checker. Check model invariants in each view and
%% state invariants against the completed implementation, without demanding
%% one global final abstract state for a causal execution.
causal(Model, Context, Branches, History, Expected, System) ->
    lists:all(fun({Branch, Events}) ->
        try
            Last = lists:foldl(fun({{I, Args}, {_, _, Result}}, State) ->
                C = lawspec_beam_model:command(Model, I),
                {ok, Next, Wanted} = lawspec_beam_model:step(C, Context, Args, State),
                true = maps:get(unit, C) orelse lawspec_beam_scalar:equal(Result, Wanted), Next
            end, Expected, lists:zip(Branch, Events)),
            lawspec_beam_model:check_state(Model#{abstract := none}, Context, System, Last), true
        catch _:_ -> false end
    end, lists:zip(Branches, History)).

by_key(Model, Context, Branches, History, Expected, Finish) ->
    Groups = lists:foldl(fun({I, {Branch, Events}}, Acc) ->
        lists:foldl(fun({Step = {Index, Args}, Event}, Groups0) ->
            KeyIndex = maps:get(key, lawspec_beam_model:command(Model, Index)),
            Key = lawspec_beam_values:render(lists:nth(KeyIndex + 1, Args)),
            Empty = lists:duplicate(length(Branches), []),
            Parts = maps:get(Key, Groups0, Empty),
            Groups0#{Key => replace(Parts, I, lists:nth(I + 1, Parts) ++ [{Step, Event}])}
        end, Acc, lists:zip(Branch, Events))
    end, #{}, numbered(lists:zip(Branches, History))),
    fold_keys(Model, Context, [maps:get(K, Groups) || K <- lists:sort(maps:keys(Groups))], Expected, Finish).
fold_keys(_, _, [], State, Finish) -> Finish(State);
fold_keys(Model, Context, [Parts | Rest], State, Finish) ->
    Branches = [[S || {S, _} <- Part] || Part <- Parts], History = [[E || {_, E} <- Part] || Part <- Parts],
    %% A key can have several legal final states when an operation returns
    %% Unit. Continue the remaining keys inside the search's final predicate,
    %% so the first legal order cannot hide another that matches abstraction.
    find_order(Model, Context, Branches, History, State,
        fun(Next) -> fold_keys(Model, Context, Rest, Next, Finish) end) =/= false.

candidates(Model, {Prefix = {Args, Steps}, Branches}) ->
    Prefixes = [{{Args, remove(Steps, I)}, Branches} || {I, _} <- numbered(Steps)],
    Drops = [{Prefix, replace(Branches, I, remove(Branch, K))}
        || {I, Branch} <- numbered(Branches), {K, _} <- numbered(Branch)],
    Smaller = [{Prefix, replace(Branches, I, replace(Branch, K, {Index, replace(Values, A, Value)}))}
        || {I, Branch} <- numbered(Branches), {K, {Index, Values}} <- numbered(Branch),
        {A, {D, V}} <- numbered(lists:zip(maps:get(arguments, lawspec_beam_model:command(Model, Index)), Values)),
        Value <- lawspec_beam_values:shrink(D, V, maps:get(table, Model))],
    Prefixes ++ Drops ++ Smaller.
shrink(Model, Case, Failure, Repeats, Budget, Shake) ->
    shrink_next(Model, candidates(Model, Case), Case, Failure, Repeats, Budget, Shake).
shrink_next(_, _, Case, Failure, _, 0, _) -> {Case, Failure};
shrink_next(_, [], Case, Failure, _, _, _) -> {Case, Failure};
shrink_next(Model, [Candidate | Rest], Case, Failure, Repeats, Budget, Shake) ->
    Found = case allowed(Model, Candidate) of false -> ok; true -> repeats(Model, Candidate, Repeats, Shake) end,
    case Found of
        ok -> shrink_next(Model, Rest, Case, Failure, Repeats, Budget - 1, Shake);
        {error, Reason} -> shrink(Model, Candidate, Reason, Repeats, Budget - 1, Shake)
    end.
repeats(_, _, 0, _) -> ok;
repeats(Model, Case, Repeats, Shake) ->
    case execute(Model, Case, Shake) of ok -> repeats(Model, Case, Repeats - 1, Shake + 1); Error -> Error end.

describe(Model, {Prefix, Branches}) ->
    Parts = [[unicode:characters_to_binary([$A + I]), <<": ">>, case B of
        [] -> <<"nothing">>;
        _ -> <<"start(); ", Commands/binary>> = lawspec_beam_model:describe(Model, {[], B}), Commands
    end] || {I, B} <- numbered(Branches)],
    Joined = case Parts of
        [] -> <<"nothing">>;
        [Only] -> Only;
        _ -> [lists:join(<<", ">>, lists:droplast(Parts)), <<" and ">>, lists:last(Parts)]
    end,
    iolist_to_binary([lawspec_beam_model:describe(Model, Prefix), <<", then ">>, Joined, <<" at the same time">>]).

check(Model) -> check(Model, #{}).
check(Model, Options) ->
    Cases = maps:get(cases, Options, 50), Repeats = maps:get(repeats, Options, 10),
    Shrinks = maps:get(max_shrinks, Options, 300), Threads = maps:get(threads, Options, 3),
    Length = maps:get(branch_length, Options, 5), Seed = lawspec_beam_model:seed(Options),
    true = maps:get(shared, Model),
    true = lists:all(fun(N) -> is_integer(N) andalso N > 0 end, [Cases, Repeats, Threads, Length]),
    true = is_integer(Shrinks) andalso Shrinks >= 0,
    check_cases(Model, 0, Cases, Repeats, Shrinks, Threads, Length, Seed, Seed bxor 16#5bd1e995).
check_cases(_, N, N, _, _, _, _, _, _) -> ok;
check_cases(Model, N, Cases, Repeats, Shrinks, Threads, Length, Seed, Random) ->
    {Case, R1} = generate(Model, Random, 1 + N rem 8, Threads, Length),
    {Shake, R2} = lawspec_beam_random:next(R1),
    case repeats(Model, Case, Repeats, Shake) of
        ok -> check_cases(Model, N + 1, Cases, Repeats, Shrinks, Threads, Length, Seed, R2);
        {error, Failure} ->
            {Smaller, Found} = shrink(Model, Case, Failure, max(2, Repeats div 2), Shrinks, Shake),
            error({lawspec, {model_inconsistent, maps:get(name, Model), maps:get(consistency, Model),
                #{seed => Seed, 'case' => N, shake => Shake, run => Smaller,
                    description => describe(Model, Smaller), failure => Found}}})
    end.

numbered(Vs) -> lists:zip(lists:seq(0, length(Vs) - 1), Vs).
remove(Vs, I) -> {Before, [_ | Rest]} = lists:split(I, Vs), Before ++ Rest.
replace(Vs, I, V) -> {Before, [_ | Rest]} = lists:split(I, Vs), Before ++ [V | Rest].
tuple_branches(Branches) -> list_to_tuple([list_to_tuple(B) || B <- Branches]).
positions(Branches) -> list_to_tuple(lists:duplicate(length(Branches), 0)).
advance(Positions, I) -> setelement(I, Positions, element(I, Positions) + 1).
pending(Branches, Positions) -> [{I, element(K + 1, B)}
    || I <- lists:seq(1, tuple_size(Branches)), B <- [element(I, Branches)],
        K <- [element(I, Positions)], K < tuple_size(B)].
