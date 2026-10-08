%% A barrier makes overlap observable without a wall-clock speed threshold.
%% The first step can finish only after the second reaches finish/1.
%% ref:DEC-acceptance-with-mutants
-module(beam_async_probe).
-export([probe/2]).
probe(Body, Unit) ->
    Owner = self(),
    {Pid, Monitor} = spawn_monitor(fun() -> loop(monitor(process, Owner), #{}, []) end),
    Request = fun(Kind, N) ->
        Ref = make_ref(), Pid ! {self(), Ref, Kind, N},
        receive {Ref, ok} -> Unit after 2000 -> error(async_steps_did_not_overlap) end
    end,
    try
        Result = Body(fun(N) -> Request(meet, N) end, fun(N) -> Request(finish, N) end),
        Ref = make_ref(), Pid ! {self(), Ref, trace, 0},
        receive {Ref, Trace} -> Result andalso Trace =:= [2, 1]
        after 2000 -> error(missing_completion_trace) end
    after
        exit(Pid, kill),
        receive {'DOWN', Monitor, process, Pid, _} -> ok end
    end.

loop(Owner, Waiting, Trace) ->
    receive
        {'DOWN', Owner, process, _, _} -> ok;
        {From, Ref, meet, N} ->
            Updated = Waiting#{N => {From, Ref}},
            case {maps:is_key(1, Updated), maps:find(2, Updated)} of
                {true, {ok, Second}} -> reply(Second);
                _ -> ok
            end,
            loop(Owner, Updated, Trace);
        {From, Ref, finish, N} ->
            case N of 2 -> reply(maps:get(1, Waiting)); _ -> ok end,
            reply({From, Ref}),
            loop(Owner, Waiting, Trace ++ [N]);
        {From, Ref, trace, _} -> From ! {Ref, Trace}, loop(Owner, Waiting, Trace)
    end.
reply({Pid, Ref}) -> Pid ! {Ref, ok}.
