%% @doc Scenario histories carry vector clocks through sends, receives and
%% fork/join. Consistency depends on these message edges as well as each
%% caller's own order; real time is required only for linearizability.
%% ref:DEC-sessions-by-construction ref:DEC-stateful-models-linearizability
%% ref:wing-gong-linearizability
-module(lawspec_beam_history).
-export([consistent/6, happened_before/2]).

happened_before(#{return_clock := Returned}, #{call_clock := Called}) ->
    maps:fold(fun(Process, Count, Yes) -> Yes andalso maps:get(Process, Called, 0) >= Count end, true, Returned).

%% Each event has command (the model command index), arguments, result,
%% called/returned (the atomic interval clock), process, call_clock and
%% return_clock. Completed calls alone enter the history.
consistent(Model, Context, Events, Expected, Final, System) ->
    History = list_to_tuple(Events), Indices = lists:seq(0, length(Events) - 1),
    Mode = maps:get(consistency, Model),
    Preds = list_to_tuple([mask([J || J <- Indices, J =/= I,
        before(Mode, element(J + 1, History), element(I + 1, History))]) || I <- Indices]),
    Judge = fun(CompareFinal) -> fun(State) ->
        try
            Equal = case {CompareFinal, Final} of
                {true, {some, Actual}} -> lawspec_beam_scalar:equal(Actual, State);
                _ -> true
            end,
            case Equal of
                false -> false;
                true -> lawspec_beam_model:check_state(Model#{abstract := none}, Context, System, State), true
            end
        catch _:_ -> false end
    end end,
    case Mode of
        <<"causal">> ->
            Processes = lists:usort([maps:get(process, E) || E <- Events]),
            case Processes of
                [] -> (Judge(false))(Expected);
                _ -> lists:all(fun(Process) ->
                    Own = [I || I <- Indices, maps:get(process, element(I + 1, History)) =:= Process],
                    Visible = lists:usort(Own ++ [J || J <- Indices, I <- Own, J =/= I,
                        happened_before(element(J + 1, History), element(I + 1, History))]),
                    search(Model, Context, History, Preds, Visible, mask(Own), Expected, Judge(false))
                end, Processes)
            end;
        _ ->
            Checked = case Mode of <<"eventual">> -> 0; _ -> mask(Indices) end,
            search(Model, Context, History, Preds, Indices, Checked, Expected, Judge(true))
    end.
before(<<"linearizable">>, #{returned := End}, #{called := Begin}) -> End < Begin;
before(_, A, B) -> happened_before(A, B).
mask(Indices) -> lists:foldl(fun(I, Bits) -> Bits bor (1 bsl I) end, 0, Indices).

search(Model, Context, History, Preds, Members, Checked, Expected, Judge) ->
    Setup = #{model => Model, context => Context, history => History, predecessors => Preds,
        members => Members, full => mask(Members), checked => Checked, judge => Judge},
    {Result, _} = visit(Setup, 0, Expected, #{}), Result.
visit(#{full := Full, judge := Judge}, Full, State, Seen) -> {Judge(State), Seen};
visit(Setup, Done, State, Seen) ->
    Key = {Done, State},
    case maps:is_key(Key, Seen) of
        true -> {false, Seen};
        false -> choose(Setup, maps:get(members, Setup), Done, State, Seen#{Key => true})
    end.
choose(_, [], _, _, Seen) -> {false, Seen};
choose(Setup, [I | Rest], Done, State, Seen) ->
    Bit = 1 bsl I,
    Dependencies = element(I + 1, maps:get(predecessors, Setup)) band maps:get(full, Setup),
    Available = Done band Bit =:= 0 andalso Dependencies band Done =:= Dependencies,
    Outcome = case Available of
        false -> {false, Seen};
        true ->
            Model = maps:get(model, Setup), Context = maps:get(context, Setup),
            #{command := Index, arguments := Args, result := Result} = element(I + 1, maps:get(history, Setup)),
            Command = lawspec_beam_model:command(Model, Index),
            case lawspec_beam_model:step(Command, Context, Args, State) of
                invalid -> {false, Seen};
                {ok, Next, Wanted} ->
                    Ignore = maps:get(checked, Setup) band Bit =:= 0 orelse maps:get(unit, Command),
                    case Ignore orelse lawspec_beam_scalar:equal(Result, Wanted) of
                        true -> visit(Setup, Done bor Bit, Next, Seen);
                        false -> {false, Seen}
                    end
            end
    end,
    case Outcome of
        {true, _} -> Outcome;
        {false, S} -> choose(Setup, Rest, Done, State, S)
    end.
