%% @doc Checked scenario programs run real concurrent processes, carrying
%% vector clocks with messages and joining every child before final checks.
%% ref:DEC-sessions-by-construction ref:DEC-stateful-models-linearizability
%% ref:DEC-portable-seeded-generation
-module(lawspec_beam_scenario).
-export([new/1, execute/4, run/4, victim/2, schedules/2]).

new(Spec) when is_binary(Spec) ->
    Forms = lawspec_beam_values:read_descriptor(Spec),
    [<<"scenario">>, {quoted, Title}, _] = hd(Forms),
    [<<"process">> | Body] = form(<<"process">>, Forms, []),
    {Acts, _, Branches} = annotate(Body, 1, true),
    #{title => Title, channels => tl(form(<<"channels">>, Forms, [<<"channels">>])),
        mailboxes => tl(form(<<"mailboxes">>, Forms, [<<"mailboxes">>])),
        acts => Acts, branches => Branches, wire => form(<<"wire">>, Forms, none)};
new(Program) when is_map(Program) -> Program.
form(Key, Forms, Default) ->
    case [F || [K | _] = F <- Forms, K =:= Key] of [F] -> F; [] -> Default end.

%% Stable identities follow source order. Pars inside or-else handlers are
%% real processes too, but portable crash schedules do not select them.
annotate([], Next, _) -> {[], Next, []};
annotate([Act | Rest], Next, Eligible) ->
    {A, N1, B1} = annotate_act(Act, Next, Eligible),
    {As, N2, B2} = annotate(Rest, N1, Eligible), { [A | As], N2, B1 ++ B2 }.
annotate_act([<<"par">> | Branches], Next, Eligible) ->
    {Bs, N, Found} = annotate_branches(Branches, Next, Eligible), {{par, Bs}, N, Found};
annotate_act([<<"receiveor">>, Name, Variable, [<<"process">> | Body]], Next, _) ->
    {Acts, N, _} = annotate(Body, Next, false), {{receive_or, Name, Variable, Acts}, N, []};
annotate_act(Act, Next, _) -> {Act, Next, []}.
annotate_branches([], Next, _) -> {[], Next, []};
annotate_branches([[<<"process">> | Acts] | Rest], Next, Eligible) ->
    {Body, N1, B1} = annotate(Acts, Next + 1, Eligible),
    {Bs, N2, B2} = annotate_branches(Rest, N1, Eligible),
    {[{Next, Body} | Bs], N2, [{Next, length(Acts)} || Eligible] ++ B1 ++ B2}.

victim(#{branches := []}, _) -> none;
victim(#{branches := Branches}, Shake) ->
    R0 = lawspec_beam_random:seed(Shake bxor 16#c3a5c85c97cb3127),
    {I, R1} = lawspec_beam_random:below(length(Branches), R0),
    {Identity, Length} = lists:nth(I + 1, Branches),
    {At, _} = lawspec_beam_random:below(Length + 1, R1), {Identity, At}.
schedules(Seed, Runs) ->
    {Cases, _} = lists:mapfoldl(fun(I, R) ->
        {Shake, Next} = lawspec_beam_random:next(R),
        {{Shake, #{network => I rem 3 =:= 1, crash => I rem 3 =:= 2}}, Next}
    end, lawspec_beam_random:seed(Seed bxor 16#2545f4914f6cdd1d), lists:seq(0, Runs - 1)), Cases.

execute(Model, Spec, Shake, Options) ->
    case run(Model, Spec, Shake, Options) of {ok, _} -> ok; {error, _} = Error -> Error end.
run(Model, Spec, Shake, Options) ->
    Program = new(Spec),
    try
        true = maps:get(shared, Model),
        %% Keep the public compiler gate until the real network path is
        %% connected. An explicitly requested network run must never fall
        %% back to this in-memory path.
        case maps:get(network, Options, false) of
            true -> error({lawspec, scenario_network_not_available});
            false -> ok
        end,
        Victim = case maps:find(victim, Options) of
            {ok, Chosen} -> Chosen;
            error -> case maps:get(crash, Options, false) of true -> victim(Program, Shake); false -> none end
        end,
        case Victim of
            none -> ok;
            {Id, At} ->
                case lists:keyfind(Id, 1, maps:get(branches, Program)) of
                    {Id, Length} when is_integer(At), At >= 0, At =< Length -> ok;
                    _ -> error({lawspec, {invalid_scenario_victim, Victim}})
                end
        end,
        Start = [lawspec_beam_values:minimal(D, maps:get(table, Model)) || D <- maps:get(start_arguments, Model)],
        lawspec_beam_model:with_system(Model, Start, 0, fun(Context, System, Expected) ->
            lawspec_beam_scenario_io:with_io(maps:get(channels, Program),
                sends(maps:get(acts, Program), maps:get(mailboxes, Program)), fun(Hub) ->
                History = ets:new(?MODULE, [ordered_set, public]),
                try
                    Commands = maps:from_list([{maps:get(name, C), I - 1}
                        || {I, C} <- lists:enumerate(tuple_to_list(maps:get(commands, Model)))]),
                    Setup = #{program => Program, model => Model, context => Context, system => System,
                        hub => Hub, history => History, tick => atomics:new(1, []), commands => Commands,
                        shake => Shake, victim => Victim, timeout => maps:get(receive_timeout, Options, 5000)},
                    {Outcome, Clock} = process(Setup, root, maps:get(acts, Program), #{}, #{}, #{},
                        lawspec_beam_random:seed(Shake)),
                    Events = [E || {I, E} <- ets:tab2list(History), is_integer(I)],
                    Report = #{title => maps:get(title, Program), history => Events, outcome => Outcome,
                        clock => Clock, shake => Shake, victim => Victim},
                    case ets:lookup(History, failure) of
                        [{failure, Failure}] -> {error, maps:merge(Report, Failure)};
                        [] when Outcome =:= failed, Victim =:= none -> {error, Report#{reason => process_failed}};
                        [] ->
                            Final = final(Model, Context, System),
                            case lawspec_beam_history:consistent(Model, Context, Events, Expected, Final, System) of
                                true -> {ok, Report#{final => Final}};
                                false -> {error, Report#{reason => no_consistent_order, final => Final}}
                            end
                    end
                after ets:delete(History) end
            end)
        end)
    catch Class:Reason:Stack ->
        {error, #{title => maps:get(title, Program), shake => Shake,
            reason => {raised, Class, Reason}, stack => Stack}}
    end.
final(#{abstract := none}, _, _) -> none;
final(Model = #{abstract := Abstract}, Context, System) ->
    State = case maps:get(actor, Model) of true -> lawspec_beam_actors:state(System); false -> System end,
    {some, lawspec_beam_model:callback(Abstract, Context, [State])}.

process(Setup, Identity, Acts, Values, Ends, Clock, Random) ->
    Hub = maps:get(hub, Setup),
    try
        case Identity of root -> ok; _ -> lawspec_beam_scenario_io:enter(Hub, Identity) end,
        State = #{id => Identity, values => Values, ends => Ends, clock => Clock,
            random => Random, crashable => true},
        {Outcome, Last} = steps(Setup, Acts, 0, State), {Outcome, maps:get(clock, Last)}
    catch Class:Reason:Stack ->
        ets:insert_new(maps:get(history, Setup), {failure, #{process => Identity,
            reason => {raised, Class, Reason}, stack => Stack}}),
        {failed, Clock}
    after lawspec_beam_scenario_io:leave(Hub, Identity) end.
steps(Setup, Acts, Index, State) ->
    Interrupted = ets:member(maps:get(history, Setup), failure) orelse
        (maps:get(crashable, State) andalso maps:get(victim, Setup) =:= {maps:get(id, State), Index}),
    case {Interrupted, Acts} of
        {true, _} -> {failed, State};
        {false, []} -> {done, State};
        {false, [Act | Rest]} ->
            case act(Setup, Act, State) of
                {continue, Next} -> steps(Setup, Rest, Index + 1, Next);
                {finish, Result} -> Result
            end
    end.

act(Setup, [<<"call">>, Name, Bound | Operands], State = #{values := Values}) ->
    Model = maps:get(model, Setup), Context = maps:get(context, Setup),
    Index = maps:get(Name, maps:get(commands, Setup)), Command = lawspec_beam_model:command(Model, Index),
    Args = [value(O, Values) || O <- Operands],
    S1 = bump(perturb(State)), CallClock = maps:get(clock, S1),
    Called = tick(Setup), System = maps:get(system, Setup),
    {Result, System} = lawspec_beam_model:invoke(Model, Context, Command, Args, System),
    Returned = tick(Setup), S2 = bump(S1),
    Event = #{command => Index, arguments => Args, result => Result, process => maps:get(id, State),
        called => Called, returned => Returned, call_clock => CallClock, return_clock => maps:get(clock, S2)},
    ets:insert(maps:get(history, Setup), {Called, Event}),
    NextValues = case Bound of none -> Values; _ -> Values#{Bound => Result} end,
    {continue, S2#{values := NextValues}};
act(Setup, [<<"send">>, Name, Operand], State) ->
    Destination = destination(Setup, Name, State),
    {Value, S1} = give(Operand, State), S2 = bump(perturb(S1)),
    ok = lawspec_beam_scenario_io:send(maps:get(hub, Setup), maps:get(id, State), Destination, Value, maps:get(clock, S2)),
    {continue, S2};
act(Setup, [<<"receive">>, Name, Variable], State) -> accept(Setup, Name, Variable, none, State);
act(Setup, {receive_or, Name, Variable, Handler}, State) -> accept(Setup, Name, Variable, Handler, State);
act(Setup, {par, Branches}, State) ->
    Program = maps:get(program, Setup),
    {Plans, Ends} = divide(Branches, maps:get(channels, Program), maps:get(ends, State)),
    Children = [#{id => Id, ends => maps:values(Mine), sends => sends(Body, maps:get(mailboxes, Program)),
        receives => [N || N <- maps:get(mailboxes, Program), receives(Body, N)]} || {Id, Body, Mine} <- Plans],
    ok = lawspec_beam_scenario_io:fork(maps:get(hub, Setup), maps:get(id, State), Children),
    Outcomes = lawspec_beam_runtime:concurrently([
        fun() -> process(Setup, Id, Body, maps:get(values, State), Mine, maps:get(clock, State),
            lawspec_beam_random:seed(maps:get(shake, Setup) bxor (I * 16#9e3779b97f4a7c15))) end
        || {I, {Id, Body, Mine}} <- lists:enumerate(Plans)]),
    Clock = lists:foldl(fun({_, C}, Acc) -> merge_clock(Acc, C) end, maps:get(clock, State), Outcomes),
    Next = bump(State#{ends := Ends, clock := Clock}),
    case lists:keymember(failed, 1, Outcomes) of
        true -> {finish, {failed, Next}};
        false -> {continue, Next}
    end;
act(_, [<<"expect">>, Variable, Constant], State = #{values := Values}) ->
    Actual = maps:get(Variable, Values), Wanted = value(Constant, #{}),
    case lawspec_beam_scalar:equal(Actual, Wanted) of
        true -> {continue, State};
        false -> error({lawspec, {scenario_expectation, Variable, Actual, Wanted}})
    end.

accept(Setup, Name, Variable, Handler, State = #{ends := Ends, values := Values}) ->
    Destination = destination(Setup, Name, State),
    Hub = maps:get(hub, Setup), Identity = maps:get(id, State),
    case lawspec_beam_scenario_io:receive_value(Hub, Identity, Destination, maps:get(timeout, Setup)) of
        gone when Handler =:= none -> {finish, {failed, State}};
        gone ->
            case Destination of {'end', _, _} -> lawspec_beam_scenario_io:abandon(Hub, Identity, Destination); _ -> ok end,
            {finish, steps(Setup, Handler, 0, State#{ends := maps:remove(Name, Ends), crashable := false})};
        {value, Value, Sent} ->
            Next = bump(State#{clock := merge_clock(maps:get(clock, State), Sent)}),
            case Value of
                {lawspec_scenario_end, Channel, Side} -> {continue, Next#{ends := Ends#{Variable => {'end', Channel, Side}}}};
                _ -> {continue, Next#{values := Values#{Variable => Value}}}
            end
    end.
destination(#{program := #{mailboxes := Boxes}}, Name, #{ends := Ends}) ->
    case lists:member(Name, Boxes) of true -> {mailbox, Name}; false -> maps:get(Name, Ends) end.
give([<<"var">>, Name] = Operand, State = #{ends := Ends, values := Values}) ->
    case maps:take(Name, Ends) of
        {{'end', Channel, Side}, Rest} -> {{lawspec_scenario_end, Channel, Side}, State#{ends := Rest}};
        error -> {value(Operand, Values), State}
    end;
give(Operand, State) -> {value(Operand, #{}), State}.
value([<<"var">>, Name], Values) -> maps:get(Name, Values);
value([<<"int">>, Number], _) -> Number;
value([<<"bool">>, Boolean], _) -> Boolean =:= <<"true">>;
value([<<"text">>, {quoted, Text}], _) -> Text;
value([<<"tag">>, Tag], _) -> {ls_data, Tag, []}.
tick(Setup) -> atomics:add_get(maps:get(tick, Setup), 1, 1).
bump(State = #{id := Identity, clock := Clock}) -> State#{clock := Clock#{Identity => maps:get(Identity, Clock, 0) + 1}}.
merge_clock(A, B) -> maps:fold(fun(P, N, Acc) -> Acc#{P => max(maps:get(P, Acc, 0), N)} end, A, B).
perturb(State = #{random := Random}) ->
    {Choice, Next} = lawspec_beam_random:below(4, Random),
    case Choice of 0 -> ok; 1 -> erlang:yield(); _ -> receive after 1 -> ok end end,
    State#{random := Next}.

divide(Branches, Channels, Ends) ->
    Users = lists:foldl(fun({I, {_, Body}}, Acc) ->
        lists:foldl(fun(N, A) -> A#{N => maps:get(N, A, []) ++ [I]} end, Acc, names(Body))
    end, #{}, lists:enumerate(Branches)),
    lists:mapfoldl(fun({I, {Id, Body}}, Remaining) ->
        {Mine, Rest} = lists:foldl(fun(N, {Own, Left}) ->
            case maps:take(N, Left) of
                {End, More} -> {Own#{N => End}, More};
                error -> case lists:member(N, Channels) of
                    false -> {Own, Left};
                    true ->
                        Side = length(lists:takewhile(fun(J) -> J =/= I end, maps:get(N, Users))),
                        {Own#{N => {'end', N, Side}}, Left}
                end
            end
        end, {#{}, Remaining}, names(Body)),
        {{Id, Body, Mine}, Rest}
    end, Ends, lists:enumerate(Branches)).
names(Acts) -> lists:usort(lists:append([case Act of
    [<<"send">>, N, [<<"var">>, V]] -> [N, V];
    [<<"send">>, N, _] -> [N];
    [<<"receive">>, N, _] -> [N];
    {receive_or, N, _, Handler} -> [N | names(Handler)];
    {par, Branches} -> lists:append([names(Body) || {_, Body} <- Branches]);
    _ -> []
end || Act <- Acts])).
sends(Acts, Boxes) -> maps:from_list([{N, count_sends(Acts, N)} || N <- Boxes]).
count_sends(Acts, Name) -> lists:sum([case Act of
    [<<"send">>, Name, _] -> 1;
    {par, Branches} -> lists:sum([count_sends(Body, Name) || {_, Body} <- Branches]);
    _ -> 0
end || Act <- Acts]).
receives(Acts, Name) -> lists:any(fun(Act) -> case Act of
    [<<"receive">>, Name, _] -> true;
    {par, Branches} -> lists:any(fun({_, Body}) -> receives(Body, Name) end, Branches);
    _ -> false
end end, Acts).
