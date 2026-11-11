%% @doc Portable stateful model runs over checked logical callbacks. A fresh
%% context owns each generation, replay and shrink attempt. Actor models use
%% the same persistent gen_servers and OTP supervisors as production APIs.
%% ref:DEC-stateful-models-linearizability ref:DEC-portable-seeded-generation
-module(lawspec_beam_model).
-export([
    new/5,
    check/1, check/2,
    generate/5,
    next_step/7,
    report/6,
    incomplete/3,
    rejected_note/1,
    simulate/2,
    execute/2,
    shrink/4,
    candidates/2,
    describe/2,
    command/2,
    admits/2,
    shifted/2,
    with_context/3,
    with_system/4,
    initial/2,
    step/4,
    invoke/5,
    check_state/4,
    callback/3,
    seed/1
]).

%% Callbacks receive the case context and a list of logical arguments. The
%% generated context factory installs production abilities in a fresh owned
%% scope; no mutable handlers or workflow state are shared between attempts.
new(Spec, {StartRun, StartModel}, Callbacks, Abstract, Invariants) ->
    Forms = lawspec_beam_values:read_descriptor(Spec),
    [<<"machine">>, Name, Sharing] = hd(Forms),
    Start = fields(tl(form(<<"start">>, Forms))),
    CommandForms = [F || [<<"command">> | _] = F <- Forms],
    Kinds = tl(form(<<"invariants">>, Forms)),
    require(length(CommandForms) =:= length(Callbacks), model_command_callbacks),
    require(length(Kinds) =:= length(Invariants), model_invariant_callbacks),
    All = [read_command(F, C) || {F, C} <- lists:zip(CommandForms, Callbacks)],
    Restarts = [C || C = #{restart := true} <- All],
    require(length(Restarts) =< 1, model_restart_callbacks),
    Commands = [C || C = #{restart := false} <- All],
    Actor = flag(<<"actor">>, Forms),
    Consistency = hd(tl(form(<<"consistency">>, Forms))),
    require(lists:member(Sharing, [<<"linear">>, <<"shared">>]), model_invalid_sharing),
    require(
        lists:member(Consistency, [
            <<"linearizable">>, <<"sequential">>, <<"causal">>, <<"eventual">>
        ]),
        model_invalid_consistency
    ),
    require(
        Consistency =/= <<"eventual">> orelse Abstract =/= none, model_eventual_requires_abstraction
    ),
    require(not Actor orelse Sharing =:= <<"shared">>, model_actor_must_be_shared),
    require(Actor orelse Restarts =:= [], model_restart_requires_actor),
    Crash = #{
        name => <<"crash">>,
        arguments => [],
        state => 0,
        unit => true,
        needs => [],
        shifts => [],
        key => none,
        restart => false,
        kind => crash
    },
    #{
        name => Name,
        shared => Sharing =:= <<"shared">>,
        actor => Actor,
        table => maps:from_list([{N, D} || [<<"data">>, N | _] = D <- Forms]),
        start_arguments => maps:get(<<"arguments">>, Start),
        start_indices => maps:get(<<"indices">>, Start),
        start_run => StartRun,
        start_model => StartModel,
        commands => list_to_tuple(Commands),
        steps => list_to_tuple(Commands ++ [Crash || Actor]),
        restart =>
            case Restarts of
                [R] -> R;
                [] -> none
            end,
        abstract => Abstract,
        invariants => lists:zip(Kinds, Invariants),
        per_key => flag(<<"perkey">>, Forms),
        consistency => Consistency,
        context => fun(Body) -> Body(make_ref()) end
    }.

read_command([<<"command">>, Name | Forms], {Run, Reference, When}) ->
    F = fields(Forms),
    #{
        name => Name,
        arguments => maps:get(<<"arguments">>, F),
        state => one(<<"state">>, F),
        unit => one(<<"unit">>, F) =:= <<"true">>,
        needs => maps:get(<<"needs">>, F),
        shifts => maps:get(<<"shifts">>, F),
        key =>
            case one(<<"key">>, F) of
                <<"none">> -> none;
                I -> I
            end,
        restart => one(<<"restart">>, F) =:= <<"true">>,
        kind => command,
        run => Run,
        reference => Reference,
        'when' => When
    }.
fields(Forms) -> maps:from_list([{K, Vs} || [K | Vs] <- Forms]).
form(Key, Forms) -> hd([F || [K | _] = F <- Forms, K =:= Key]).
one(Key, Fields) ->
    [V] = maps:get(Key, Fields),
    V.
flag(Key, Forms) -> lists:member([Key, <<"true">>], Forms).
require(true, _) -> ok;
require(false, Reason) -> error({lawspec, Reason}).

command(#{steps := Steps}, I) when is_integer(I), I >= 0, I < tuple_size(Steps) ->
    element(I + 1, Steps).
admits(#{needs := Needs}, Indices) ->
    lists:all(
        fun
            ({[<<"atleast">>, N], I}) -> I >= N;
            ({[<<"exactly">>, N], I}) -> I =:= N
        end,
        lists:zip(Needs, Indices)
    ).
shifted(#{shifts := Shifts}, Indices) ->
    [
        case Shift of
            [<<"by">>, N] -> I + N;
            [<<"to">>, N] -> N
        end
     || {Shift, I} <- lists:zip(Shifts, Indices)
    ].

with_context(#{context := Factory} = Model, StartArgs, Body) ->
    Factory(fun(Value) -> Body(#{value => Value, start => StartArgs, model => Model}) end).
callback(Fun, #{value := Value}, Arguments) -> Fun(Value, Arguments).
initial(#{start_model := Start}, #{start := Args} = Context) -> callback(Start, Context, Args).

%% Invalid references remove a generation/shrink candidate; they never make
%% the implementation's exception into a passing test.
step(#{kind := crash}, Context = #{model := Model}, [], State) ->
    try
        Next =
            case maps:get(restart, Model) of
                none -> initial(Model, Context);
                #{reference := Ref} -> callback(Ref, Context, [State])
            end,
        {ok, Next, ls_unit}
    catch
        _:_ -> invalid
    end;
step(#{reference := Ref, 'when' := When, unit := Unit}, Context, Args, State) ->
    try
        case When =:= none orelse callback(When, Context, [State]) =:= true of
            false ->
                invalid;
            true ->
                Out = callback(Ref, Context, Args ++ [State]),
                case Unit of
                    true ->
                        {ok, Out, ls_unit};
                    false ->
                        {ls_data, _, [Reply, Next]} = Out,
                        {ok, Next, Reply}
                end
        end
    catch
        _:_ -> invalid
    end.

model_bound(N, _) when is_integer(N) -> N;
model_bound([<<"index">>, I], Indices) ->
    lists:nth(I + 1, Indices);
model_bound([Op, A, B], Indices) ->
    X = model_bound(A, Indices),
    Y = model_bound(B, Indices),
    case Op of
        <<"+">> -> X + Y;
        <<"-">> -> X - Y;
        <<"*">> -> X * Y
    end.
model_base([<<"dependent">>, Base | _]) -> Base;
model_base(D) -> D.
model_argument([<<"dependent">>, [<<"int">>, Name, Lo, Hi] | Conditions], Indices) ->
    {L, H} = lists:foldl(
        fun([Op, E], {Low, High}) ->
            N = model_bound(E, Indices),
            Min =
                N +
                    case Op of
                        <<">">> -> 1;
                        _ -> 0
                    end,
            Max =
                N -
                    case Op of
                        <<"<">> -> 1;
                        _ -> 0
                    end,
            NextLow =
                case lists:member(Op, [<<">">>, <<">=">>, <<"==">>]) of
                    true ->
                        case Low of
                            none -> Min;
                            _ -> max(Low, Min)
                        end;
                    false ->
                        Low
                end,
            NextHigh =
                case lists:member(Op, [<<"<">>, <<"<=">>, <<"==">>]) of
                    true ->
                        case High of
                            none -> Max;
                            _ -> min(High, Max)
                        end;
                    false ->
                        High
                end,
            {NextLow, NextHigh}
        end,
        {Lo, Hi},
        Conditions
    ),
    [<<"int">>, Name, L, H];
model_argument(D, _) ->
    D.
model_arguments(Command, Indices) ->
    [model_argument(D, Indices) || D <- maps:get(arguments, Command)].
empty_arguments(Ds) ->
    lists:any(
        fun
            ([<<"int">>, _, Lo, Hi]) when is_integer(Lo), is_integer(Hi) -> Lo > Hi;
            ([<<"oneof">>, _]) -> true;
            (_) -> false
        end,
        Ds
    ).
valid_arguments(Command, Indices, Args) ->
    lists:all(
        fun
            ({[<<"int">>, _, Lo, Hi], N}) ->
                (Lo =:= none orelse N >= Lo) andalso (Hi =:= none orelse N =< Hi);
            (_) ->
                true
        end,
        lists:zip(model_arguments(Command, Indices), Args)
    ).

simulate(Model, {StartArgs, Steps}) ->
    with_context(Model, StartArgs, fun(Context) ->
        try
            simulate_steps(
                Model,
                Context,
                Steps,
                maps:get(start_indices, Model),
                initial(Model, Context),
                []
            )
        catch
            _:_ -> invalid
        end
    end).
simulate_steps(_, _, [], _, State, States) ->
    {ok, lists:reverse([State | States])};
simulate_steps(Model, Context, [{I, Args} | Steps], Indices, State, States) ->
    Command = command(Model, I),
    case admits(Command, Indices) andalso valid_arguments(Command, Indices, Args) of
        false ->
            invalid;
        true ->
            case step(Command, Context, Args, State) of
                invalid ->
                    invalid;
                {ok, Next, _} ->
                    simulate_steps(Model, Context, Steps, shifted(Command, Indices), Next, [
                        State | States
                    ])
            end
    end.

%% Random state is explicit. The draw order, boundary values and rejected
%% reference steps match the other runtimes, including one crash in eight.
%%
%% Generation honours the reference. A step is drawn among the commands
%% enabled at the model state: typestate admits them, their precondition
%% holds, and some arguments are inside the reference's refinements. When a
%% command's argument tuples are few (FINITE_STEPS), each is tried against
%% the reference and one valid tuple is chosen, as QuickCheck state machines
%% generate from a precondition. Otherwise arguments are drawn and checked
%% again, up to STEP_ATTEMPTS times, and every draw the reference rejects is
%% counted. A run where the reference rejected more draws than it accepted
%% shows little, so its check is incomplete, never passed.
%% ref:DEC-honest-model-steps
-define(FINITE_STEPS, 64).
-define(STEP_ATTEMPTS, 8).

%% A generated run, how many of its drawn steps the reference rejected, and
%% the random state after it.
generate(Model, Random, Length, Size, Crashes) ->
    {StartArgs, R1} = arguments(Model, maps:get(start_arguments, Model), Random, Size),
    with_context(Model, StartArgs, fun(Context) ->
        case attempt(fun() -> initial(Model, Context) end) of
            {error, _} ->
                {{StartArgs, []}, 0, R1};
            {ok, State} ->
                {Steps, Rejected, Last} = generate_steps(
                    Model,
                    Context,
                    R1,
                    Length,
                    Size,
                    Crashes,
                    maps:get(start_indices, Model),
                    State,
                    [],
                    0
                ),
                {{StartArgs, Steps}, Rejected, Last}
        end
    end).
arguments(#{table := Table}, Ds, Random, Size) ->
    lists:mapfoldl(fun(D, R) -> lawspec_beam_values:generate(D, Table, R, Size) end, Random, Ds).
generate_steps(_, _, Random, 0, _, _, _, _, Steps, Rejected) ->
    {lists:reverse(Steps), Rejected, Random};
generate_steps(Model, Context, Random, Remaining, Size, Crashes, Indices, State, Steps, Rejected) ->
    {Taken, More, R1} = next_step(Model, Context, Random, State, Indices, Size, Crashes),
    case Taken of
        none_enabled ->
            {lists:reverse(Steps), Rejected + More, R1};
        no_step ->
            generate_steps(
                Model,
                Context,
                R1,
                Remaining - 1,
                Size,
                Crashes,
                Indices,
                State,
                Steps,
                Rejected + More
            );
        {step, {Index, _} = Step, Next} ->
            NextIndices =
                case command(Model, Index) of
                    #{kind := crash} -> Indices;
                    Command -> shifted(Command, Indices)
                end,
            generate_steps(
                Model,
                Context,
                R1,
                Remaining - 1,
                Size,
                Crashes,
                NextIndices,
                Next,
                [Step | Steps],
                Rejected + More
            )
    end.

%% The next step at a state: none_enabled when no command is enabled,
%% no_step when every draw was rejected, else {step, Step, Next}; with how
%% many drawn steps the reference rejected and the random state after it.
next_step(Model, Context, Random, State, Indices, Size, Crashes) ->
    case enabled_steps(Model, Context, State, Indices) of
        [] ->
            {none_enabled, 0, Random};
        Enabled ->
            {Choice, R1} = lawspec_beam_random:below(length(Enabled), Random),
            {Index, Tuples} = lists:nth(Choice + 1, Enabled),
            {Crash, R2} =
                case Crashes andalso maps:get(actor, Model) of
                    true ->
                        {N, R} = lawspec_beam_random:below(8, R1),
                        {N =:= 0, R};
                    false ->
                        {false, R1}
                end,
            case {Crash, Tuples} of
                {true, _} ->
                    CrashIndex = tuple_size(maps:get(commands, Model)),
                    case step(command(Model, CrashIndex), Context, [], State) of
                        invalid -> {no_step, 0, R2};
                        {ok, Next, _} -> {{step, {CrashIndex, []}, Next}, 0, R2}
                    end;
                {false, none} ->
                    draw_step(Model, Context, R2, State, Indices, Size, Index, ?STEP_ATTEMPTS, 0);
                {false, [Args]} ->
                    {ok, Next, _} = step(command(Model, Index), Context, Args, State),
                    {{step, {Index, Args}, Next}, 0, R2};
                {false, _} ->
                    {K, R3} = lawspec_beam_random:below(length(Tuples), R2),
                    Args = lists:nth(K + 1, Tuples),
                    {ok, Next, _} = step(command(Model, Index), Context, Args, State),
                    {{step, {Index, Args}, Next}, 0, R3}
            end
    end.
draw_step(_, _, Random, _, _, _, _, 0, Rejected) ->
    {no_step, Rejected, Random};
draw_step(Model, Context, Random, State, Indices, Size, Index, Attempts, Rejected) ->
    Command = command(Model, Index),
    {Args, R1} = arguments(Model, model_arguments(Command, Indices), Random, Size),
    case step(Command, Context, Args, State) of
        invalid ->
            draw_step(Model, Context, R1, State, Indices, Size, Index, Attempts - 1, Rejected + 1);
        {ok, Next, _} ->
            {{step, {Index, Args}, Next}, Rejected, R1}
    end.

%% The commands enabled at a state, each with its valid argument tuples, or
%% none to draw them.
enabled_steps(Model, Context, State, Indices) ->
    lists:append([
        enabled(Model, Context, State, Indices, I - 1, C)
     || {I, C} <- lists:enumerate(tuple_to_list(maps:get(commands, Model)))
    ]).
enabled(Model, Context, State, Indices, Index, Command) ->
    Ds = model_arguments(Command, Indices),
    case
        admits(Command, Indices) andalso not empty_arguments(Ds) andalso
            holds(Command, Context, State)
    of
        false ->
            [];
        true ->
            Table = maps:get(table, Model),
            Domains = [lawspec_beam_values:finite(D, Table, ?FINITE_STEPS) || D <- Ds],
            Tuples =
                case lists:member(none, Domains) of
                    true -> none;
                    false -> lawspec_beam_values:product(Domains, ?FINITE_STEPS)
                end,
            case Tuples of
                none ->
                    [{Index, none}];
                _ ->
                    %% Outside the reference: not a step here.
                    case [T || T <- Tuples, step(Command, Context, T, State) =/= invalid] of
                        [] -> [];
                        Valid -> [{Index, Valid}]
                    end
            end
    end.
holds(#{'when' := none}, _, _) ->
    true;
holds(#{'when' := When}, Context, State) ->
    try
        callback(When, Context, [State]) =:= true
    catch
        _:_ -> false
    end.

%% The error a run raises when the reference rejected more of its drawn
%% steps than it accepted.
incomplete(Model, Run, {Accepted, Rejected}) ->
    iolist_to_binary([
        <<"incomplete model generation: model ">>,
        maps:get(name, Model),
        <<"'s ">>,
        Run,
        <<" drew ">>,
        integer_to_binary(Rejected),
        <<" steps its reference rejected and ">>,
        integer_to_binary(Accepted),
        <<" it accepted; fewer than half of its steps are valid, so it shows little of the system">>
    ]).

%% How a failing run's rejected draws read after its failure.
rejected_note(0) ->
    <<>>;
rejected_note(Rejected) ->
    iolist_to_binary([
        <<" (the reference rejected ">>,
        integer_to_binary(Rejected),
        <<" drawn steps of this run)">>
    ]).

%% One line of JSON per model check, appended to the file
%% LAWSPEC_MODEL_REPORT names: how many runs and steps it checked, and how
%% many drawn steps the reference rejected. The report is a side channel; the
%% check's own result stands.
report(Model, Check, Runs, Steps, Rejected, Outcome) ->
    case os:getenv("LAWSPEC_MODEL_REPORT") of
        false ->
            ok;
        "" ->
            ok;
        Path ->
            try
                Line = [
                    <<"{\"model\":\"">>,
                    maps:get(name, Model),
                    <<"\",\"check\":\"">>,
                    Check,
                    <<"\",\"runs\":">>,
                    integer_to_binary(Runs),
                    <<",\"steps\":">>,
                    integer_to_binary(Steps),
                    <<",\"rejected\":">>,
                    integer_to_binary(Rejected),
                    <<",\"outcome\":\"">>,
                    Outcome,
                    <<"\"}\n">>
                ],
                _ = file:write_file(Path, Line, [append]),
                ok
            catch
                _:_ -> ok
            end
    end.

%% An actor run has a single permanent child. Its restart budget is the
%% number of steps in this case, so injected crashes cannot exhaust it.
%% A broken restart still terminates rather than looping without a bound.
with_system(Model, StartArgs, Restarts, Body) ->
    with_context(Model, StartArgs, fun(Context) ->
        Start = fun() -> callback(maps:get(start_run, Model), Context, StartArgs) end,
        case maps:get(actor, Model) of
            false ->
                Body(Context, Start(), initial(Model, Context));
            true ->
                Restart = fun(State) ->
                    case maps:get(restart, Model) of
                        none -> Start();
                        #{run := Run} -> callback(Run, Context, [State])
                    end
                end,
                Spec = lawspec_beam_actors:supervisor(
                    one_for_one,
                    Restarts,
                    1000000,
                    [{model, permanent, lawspec_beam_actors:actor(Start, Restart)}]
                ),
                lawspec_beam_actors:with_spec(Spec, fun(Supervisor) ->
                    Body(
                        Context,
                        lawspec_beam_actors:child(Supervisor, model),
                        initial(Model, Context)
                    )
                end)
        end
    end).

invoke(_, _, #{kind := crash}, [], Actor) ->
    ok = lawspec_beam_actors:crash(Actor),
    {ls_unit, Actor};
invoke(#{actor := true}, Context, Command = #{run := Run, unit := Unit}, Args, Actor) ->
    Reply = lawspec_beam_actors:call(Actor, fun(State) ->
        Out = callback(Run, Context, insert_state(Command, Args, State)),
        case Unit of
            true -> {ls_unit, Out};
            false -> pair(Out)
        end
    end),
    {Reply, Actor};
invoke(#{shared := Shared}, Context, Command = #{run := Run, unit := Unit}, Args, State) ->
    Out = callback(Run, Context, insert_state(Command, Args, State)),
    case {Shared, Unit} of
        {true, _} ->
            {Out, State};
        {false, true} ->
            {ls_data, _, [Next]} = Out,
            {ls_unit, Next};
        {false, false} ->
            pair(Out)
    end.
insert_state(#{state := Position}, Args, State) ->
    {Before, After} = lists:split(Position, Args),
    Before ++ [State | After].
pair({ls_data, _, [Reply, Next]}) -> {Reply, Next}.

check_state(Model, Context, System, Expected) ->
    State =
        case maps:get(actor, Model) of
            true -> lawspec_beam_actors:state(System);
            false -> System
        end,
    case maps:get(abstract, Model) of
        none ->
            ok;
        Abstract ->
            Actual = callback(Abstract, Context, [State]),
            case lawspec_beam_scalar:equal(Actual, Expected) of
                true -> ok;
                false -> throw({model_failure, {state, Actual, Expected}})
            end
    end,
    lists:foreach(
        fun({Kind, Invariant}) ->
            Value =
                case Kind of
                    <<"model">> -> Expected;
                    <<"state">> -> State
                end,
            case callback(Invariant, Context, [Value]) of
                true -> ok;
                false -> throw({model_failure, {invariant, Kind}});
                Other -> throw({model_failure, {non_boolean_invariant, Kind, Other}})
            end
        end,
        maps:get(invariants, Model)
    ).

execute(Model, {StartArgs, Steps}) ->
    try
        with_system(Model, StartArgs, length(Steps), fun(Context, System, Expected) ->
            execute_steps(
                Model, Context, Steps, maps:get(start_indices, Model), System, Expected, 0
            )
        end)
    catch
        Class:Reason:Stack -> failure(0, Class, Reason, Stack)
    end.
execute_steps(Model, Context, Steps, Indices, System, Expected, N) ->
    try
        check_state(Model, Context, System, Expected),
        case Steps of
            [] ->
                ok;
            [{I, Args} | Rest] ->
                Command = command(Model, I),
                case admits(Command, Indices) of
                    false ->
                        throw({model_step_failure, N + 1, invalid_step});
                    true ->
                        case step(Command, Context, Args, Expected) of
                            invalid ->
                                throw({model_step_failure, N + 1, invalid_step});
                            {ok, Next, Wanted} ->
                                case
                                    attempt(fun() ->
                                        invoke(Model, Context, Command, Args, System)
                                    end)
                                of
                                    {error, Error} ->
                                        {error, Error#{step => N + 1}};
                                    {ok, {Result, After}} ->
                                        case
                                            maps:get(unit, Command) orelse
                                                lawspec_beam_scalar:equal(Result, Wanted)
                                        of
                                            false ->
                                                {error, #{
                                                    step => N + 1,
                                                    reason => {returned, Result, Wanted}
                                                }};
                                            true ->
                                                execute_steps(
                                                    Model,
                                                    Context,
                                                    Rest,
                                                    shifted(Command, Indices),
                                                    After,
                                                    Next,
                                                    N + 1
                                                )
                                        end
                                end
                        end
                end
        end
    catch
        Class:Reason:Stack -> failure(N, Class, Reason, Stack)
    end.
attempt(Body) ->
    try
        {ok, Body()}
    catch
        Class:Reason:Stack -> failure(0, Class, Reason, Stack)
    end.
failure(_, throw, {model_step_failure, Step, Reason}, _) ->
    {error, #{step => Step, reason => Reason}};
failure(Step, throw, {model_failure, Reason}, _) ->
    {error, #{step => Step, reason => Reason}};
failure(Step, Class, Reason, Stack) ->
    {error, #{step => Step, reason => {raised, Class, Reason}, stack => Stack}}.

%% Shrink in portable order: remove command chunks, then shrink each command
%% argument, then each start argument. Replay the reference before executing
%% any candidate, preserving typestate and model preconditions.
candidates(Model, {StartArgs, Steps}) ->
    Drops = [
        {StartArgs, remove(Steps, Begin, Size)}
     || Size <- halves(length(Steps) div 2),
        Begin <- lists:seq(0, length(Steps) - 1, Size)
    ],
    Arguments = [
        {StartArgs, replace(Steps, K, {I, Smaller})}
     || {K, {I, Args}} <- numbered(Steps),
        Smaller <- smaller_args(Model, maps:get(arguments, command(Model, I)), Args)
    ],
    Starts = [
        {Smaller, Steps}
     || Smaller <- smaller_args(Model, maps:get(start_arguments, Model), StartArgs)
    ],
    Drops ++ Arguments ++ Starts.
halves(0) -> [];
halves(N) -> [N | halves(N div 2)].
numbered(Values) -> lists:zip(lists:seq(0, length(Values) - 1), Values).
remove(Values, Begin, Size) ->
    {Before, Rest} = lists:split(Begin, Values),
    Before ++ lists:nthtail(min(Size, length(Rest)), Rest).
replace(Values, I, Value) ->
    {Before, [_ | Rest]} = lists:split(I, Values),
    Before ++ [Value | Rest].
smaller_args(#{table := Table}, Ds, Args) ->
    [
        replace(Args, I, V)
     || {I, {D, Arg}} <- numbered(lists:zip(Ds, Args)),
        V <- lawspec_beam_values:shrink(model_base(D), Arg, Table)
    ].

shrink(Model, Run, Failure, Budget) when is_integer(Budget), Budget >= 0 ->
    shrink_candidates(Model, candidates(Model, Run), Run, Failure, Budget).
shrink_candidates(_, _, Run, Failure, 0) ->
    {Run, Failure};
shrink_candidates(_, [], Run, Failure, _) ->
    {Run, Failure};
shrink_candidates(Model, [Candidate | Rest], Run, Failure, Budget) ->
    Result =
        case simulate(Model, Candidate) of
            invalid -> ok;
            {ok, _} -> execute(Model, Candidate)
        end,
    case Result of
        ok -> shrink_candidates(Model, Rest, Run, Failure, Budget - 1);
        {error, Found} -> shrink(Model, Candidate, Found, Budget - 1)
    end.

describe(Model, {StartArgs, Steps}) ->
    iolist_to_binary(
        lists:join(<<"; ">>, [
            describe_step(<<"start">>, StartArgs)
            | [describe_step(maps:get(name, command(Model, I)), Args) || {I, Args} <- Steps]
        ])
    ).
describe_step(Name, Args) ->
    [Name, $(, lists:join(<<", ">>, [lawspec_beam_values:render(A) || A <- Args]), $)].

seed(Options) ->
    lawspec_beam_random:seed(
        case maps:find(seed, Options) of
            {ok, N} ->
                N;
            error ->
                case os:getenv("LAWSPEC_SEED") of
                    false -> 0;
                    Text -> list_to_integer(Text)
                end
        end
    ).
check(Model) -> check(Model, #{}).
check(Model, Options) ->
    Cases = maps:get(cases, Options, 100),
    MaxLength = maps:get(max_length, Options, 20),
    Shrinks = maps:get(max_shrinks, Options, 2000),
    Seed = seed(Options),
    require(is_integer(Cases) andalso Cases > 0, model_requires_cases),
    require(is_integer(MaxLength) andalso MaxLength >= 0, model_invalid_length),
    require(is_integer(Shrinks) andalso Shrinks >= 0, model_invalid_shrinks),
    check_cases(Model, 0, Cases, MaxLength, Shrinks, Seed, Seed, {0, 0}).
check_cases(Model, N, N, _, _, _, _, {Steps, Rejected}) ->
    report(Model, <<"sequential">>, N, Steps, Rejected, <<"passed">>);
check_cases(Model, N, Cases, MaxLength, Shrinks, Seed, Random, {Steps, Rejected}) ->
    {Length, R1} = lawspec_beam_random:below(MaxLength + 1, Random),
    {Run = {_, RunSteps}, RunRejected, R2} = generate(Model, R1, Length, 1 + N rem 8, true),
    Accepted = length(RunSteps),
    Totals = {AllSteps, AllRejected} = {Steps + Accepted, Rejected + RunRejected},
    case RunRejected > Accepted of
        true ->
            report(Model, <<"sequential">>, N + 1, AllSteps, AllRejected, <<"incomplete">>),
            Message = incomplete(
                Model,
                [<<"run ">>, integer_to_binary(N + 1), <<" of ">>, integer_to_binary(Cases)],
                {Accepted, RunRejected}
            ),
            error(
                {lawspec,
                    {model_incomplete, maps:get(name, Model), #{
                        seed => Seed,
                        'case' => N,
                        run => Run,
                        accepted => Accepted,
                        rejected => RunRejected,
                        message => Message
                    }}}
            );
        false ->
            ok
    end,
    case execute(Model, Run) of
        ok ->
            check_cases(Model, N + 1, Cases, MaxLength, Shrinks, Seed, R2, Totals);
        {error, Failure} ->
            report(Model, <<"sequential">>, N + 1, AllSteps, AllRejected, <<"failed">>),
            {Smaller, Found} = shrink(Model, Run, Failure, Shrinks),
            error(
                {lawspec,
                    {model_failed, maps:get(name, Model),
                        rejected(RunRejected, #{
                            seed => Seed,
                            'case' => N,
                            run => Smaller,
                            description => describe(Model, Smaller),
                            failure => Found
                        })}}
            )
    end.

%% A failing run's details, with how many of its drawn steps the reference
%% rejected when there were any.
rejected(0, Details) -> Details;
rejected(Rejected, Details) -> Details#{rejected => Rejected, note => rejected_note(Rejected)}.
