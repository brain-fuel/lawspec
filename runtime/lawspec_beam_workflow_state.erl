%% @doc Atomic workflow policy state, virtual time, jitter and compensation
%% frames. A stage owns its admissions: caller death releases its gates.
%% Gate callbacks are checked, pure resilience definitions.
%% ref:DEC-domain-modeling-primitives ref:DEC-portable-seeded-generation
-module(lawspec_beam_workflow_state).
-behaviour(gen_server).
-export([start/1, default/0, stop/1, call/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start(Options) -> gen_server:start(?MODULE, {self(), Options}, []).
default() ->
    case gen_server:start({local, ?MODULE}, ?MODULE, {none, #{}}, []) of
        {ok, Pid} -> Pid;
        {error, {already_started, Pid}} -> Pid
    end.
stop(Pid) ->
    try gen_server:stop(Pid, normal, infinity)
    catch exit:noproc -> ok; exit:{noproc, _} -> ok end.
call(Pid, Request) ->
    case gen_server:call(Pid, Request, infinity) of
        {ok, Value} -> Value;
        {exception, Class, Reason, Stack} -> erlang:raise(Class, Reason, Stack)
    end.

init({Owner, Options}) ->
    Monitor = case Owner of none -> none; _ -> monitor(process, Owner) end,
    {ok, #{owner => Monitor, options => Options,
        time => maps:get(time, Options, 0), random => lawspec_beam_random:seed(maps:get(seed, Options, 0)),
        trace => [], states => #{}, cache => #{}, frames => #{}, stages => #{}, monitors => #{}}}.

handle_call(Request, {Caller, _}, State) ->
    try
        Current = case Request of
            {gate, _, _, Now} -> prune_dead_stages(Now, State);
            _ -> State
        end,
        request(Request, Caller, Current)
    of
        {Value, Updated} -> {reply, {ok, Value}, Updated}
    catch Class:Reason:Stack -> {reply, {exception, Class, Reason, Stack}, State} end.
handle_cast(_, State) -> {noreply, State}.
handle_info({'DOWN', Monitor, process, _, _}, State = #{owner := Monitor}) -> {stop, normal, State};
handle_info({'DOWN', Monitor, process, _, _}, State = #{monitors := Monitors}) ->
    case maps:find(Monitor, Monitors) of
        {ok, {frame, Ref}} -> {_, Updated} = request({take_frame, Ref}, self(), State), {noreply, Updated};
        {ok, {stage, Ref}} ->
            #{time := LastTime} = maps:get(Ref, maps:get(stages, State)),
            %% Cancellation releases a bulkhead and fails an outstanding
            %% half-open trial. No application or Clock callback runs here.
            {noreply, finish_stage(Ref, LastTime, false, State)};
        error -> {noreply, State}
    end;
handle_info(_, State) -> {noreply, State}.

request(options, _, State) -> {maps:get(options, State), State};
request(now, _, State) -> {maps:get(time, State), State};
request({set_time, Time}, _, State) -> {ok, State#{time := Time}};
request({sleep, Delay}, _, State = #{time := Time}) -> {ok, State#{time := Time + max(0, Delay)}};
request({jitter, Kind, Delay, Previous, Base}, _, State = #{random := Random}) ->
    {Value, Next} = lawspec_beam_policy:jitter(Kind, Delay, Previous, Base, Random),
    {Value, State#{random := Next}};
request({event, Event}, _, State = #{trace := Trace}) -> {ok, State#{trace := [Event | Trace]}};
request(trace, _, State = #{trace := Trace}) -> {lists:reverse(Trace), State};
request({cached, Key, Input, Now}, _, State = #{cache := Cache}) ->
    Live = [{K,V,Until} || {K,V,Until} <- maps:get(Key, Cache, []), Now < Until],
    Value = case [V || {K,V,_} <- Live, lawspec_beam_scalar:equal(K, Input)] of
        [Found | _] -> {some, Found}; [] -> none
    end,
    {Value, State#{cache := Cache#{Key => Live}}};
request({cache, Key, Input, Value, Now, TTL}, _, State = #{cache := Cache}) ->
    Live = [{K,V,Until} || {K,V,Until} <- maps:get(Key, Cache, []), Now < Until,
        not lawspec_beam_scalar:equal(K, Input)],
    {ok, State#{cache := Cache#{Key => [{Input, Value, Now + TTL} | Live]}}};
request(new_frame, Caller, State = #{frames := Frames, monitors := Monitors}) ->
    Ref = make_ref(), Monitor = monitor(process, Caller),
    {Ref, State#{frames := Frames#{Ref => {Monitor, []}}, monitors := Monitors#{Monitor => {frame, Ref}}}};
request({undo, Ref, Stage, Undo}, _, State = #{frames := Frames}) ->
    case maps:find(Ref, Frames) of
        {ok, {Monitor, Undos}} -> {ok, State#{frames := Frames#{Ref := {Monitor, [{Stage, Undo} | Undos]}}}};
        error -> {ok, State}
    end;
request({take_frame, Ref}, _, State = #{frames := Frames, monitors := Monitors}) ->
    case maps:take(Ref, Frames) of
        {{Monitor, Undos}, Rest} ->
            demonitor(Monitor, [flush]),
            {Undos, State#{frames := Rest, monitors := maps:remove(Monitor, Monitors)}};
        error -> {[], State}
    end;
request({new_stage, Key, Now}, Caller, State = #{stages := Stages, monitors := Monitors}) ->
    Ref = make_ref(), Monitor = monitor(process, Caller),
    Stage = #{key => Key, owner => Caller, monitor => Monitor, gates => [], time => Now},
    {Ref, State#{stages := Stages#{Ref => Stage}, monitors := Monitors#{Monitor => {stage, Ref}}}};
request({gate, Ref, Gate, Now}, _, State = #{stages := Stages, states := States}) ->
    Stage = #{key := Key, gates := Gates, owner := Owner} = maps:get(Ref, Stages),
    true = is_process_alive(Owner),
    GateKey = {Key, maps:get(kind, Gate)},
    Before = case maps:find(GateKey, States) of
        {ok, Existing} -> Existing;
        error -> (maps:get(start, Gate))(Now)
    end,
    {ls_data, _, [After, Decision]} = (maps:get(admit, Gate))(Before, Now),
    Passed = case Decision of
        {ls_data, <<"lawspec.resilience::type::Gate::Admit">>, []} -> Gates ++ [{GateKey, Gate}];
        _ -> Gates
    end,
    {Decision, State#{states := States#{GateKey => After}, stages := Stages#{Ref := Stage#{gates := Passed, time := Now}}}};
request({finish_stage, Ref, Now, Succeeded}, _, State) -> {ok, finish_stage(Ref, Now, Succeeded, State)}.

finish_stage(Ref, Now, Succeeded, State = #{stages := Stages, states := States, monitors := Monitors}) ->
    case maps:take(Ref, Stages) of
        error -> State;
        {#{monitor := Monitor, gates := Gates}, Rest} ->
            Updated = lists:foldl(fun({Key, Gate}, Values) ->
                case maps:get(finish, Gate) of
                    none -> Values;
                    Finish -> Values#{Key := Finish(maps:get(Key, Values), Now, Succeeded)}
                end
            end, States, Gates),
            demonitor(Monitor, [flush]),
            State#{states := Updated, stages := Rest, monitors := maps:remove(Monitor, Monitors)}
    end.

%% A timeout joins the worker before its monitor signal necessarily reaches
%% this server. Its dead admission must not reject the next live caller.
prune_dead_stages(Now, State = #{stages := Stages}) ->
    lists:foldl(fun({Ref, #{owner := Owner}}, Current) ->
        case is_process_alive(Owner) of
            true -> Current;
            false -> finish_stage(Ref, Now, false, Current)
        end
    end, State, maps:to_list(Stages)).
