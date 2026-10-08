%% @doc Stable mailboxes and committed checkpoints for an OTP supervision tree.
%% No application handler runs here. Real gen_server children own execution;
%% real OTP supervisors replace them, in their declared strategy and order.
%% ref:DEC-actors-otp-supervision ref:erlang-otp-supervisors
-module(lawspec_beam_actor_tree).
-behaviour(gen_server).
-export([start/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start(Spec) ->
    {Root, Public, Standalone} = case maps:get(kind, Spec) of
        actor -> {lawspec_beam_actors:supervisor(one_for_one, 0, 1, [{actor, temporary, Spec}]), [actor], true};
        supervisor -> {Spec, [], false}
    end,
    case gen_server:start(?MODULE, {self(), Root, Public, Standalone}, []) of
        {ok, Tree} ->
            case gen_server:call(Tree, await_start, infinity) of
                {ok, Handle} -> Handle;
                {error, Reason} -> error({lawspec, {actor_start_failed, Reason}})
            end;
        {error, Reason} -> error({lawspec, {actor_start_failed, Reason}})
    end.

init({Owner, Spec, Public, Standalone}) ->
    process_flag(trap_exit, true),
    Nodes = allocate(Spec, [], none, permanent, #{}),
    {ok, Root} = lawspec_beam_actor_sup:start_root(self(), Spec),
    RootMonitor = erlang:monitor(process, Root),
    RootNode = (maps:get([], Nodes))#{pid := Root, monitor := RootMonitor, status := ready},
    State = #{tree => self(), nodes => Nodes#{[] := RootNode}, public => Public, standalone => Standalone,
        owner => erlang:monitor(process, Owner), boot => starting, starters => [], start_delivered => false,
        stops => #{}, stopping => #{}, root => Root, root_monitor => RootMonitor},
    Tree = self(),
    spawn_link(fun() ->
        Result = try
            lists:foreach(fun(Child) ->
                case supervisor:start_child(Root, Child) of
                    {ok, _} -> ok;
                    {ok, _, _} -> ok;
                    {error, Why} -> throw(Why)
                end
            end, child_specs([], State)),
            ok
        catch Class:Reason -> {error, {Class, Reason}} end,
        Tree ! {booted, Result}
    end),
    {ok, State}.

handle_call(await_start, From, State = #{boot := starting, starters := Waiters}) ->
    {noreply, State#{starters := [From | Waiters]}};
handle_call(await_start, _, State = #{boot := ready, public := Id}) ->
    {reply, {ok, handle(Id, State)}, State#{start_delivered := true}};
handle_call(await_start, _, State = #{boot := {failed, Reason}}) ->
    case maps:get(pid, node([], State)) of
        none -> {stop, normal, {error, Reason}, State#{start_delivered := true}};
        _ -> {reply, {error, Reason}, State#{start_delivered := true}}
    end;
handle_call({eligible, Id}, _, State) -> {reply, not maps:get(removed, node(Id, State)), State};
handle_call({supervisor_started, Id, Pid}, From, State) -> claim(Id, Pid, From, State);
handle_call({actor_started, Id, Pid}, From, State) -> claim(Id, Pid, From, State);
handle_call({supervisor_ready, Id, Pid}, _, State) ->
    case node(Id, State) of
        Node = #{pid := Pid} ->
            Ready = put_node(Id, Node#{status := ready, restarting := false}, State),
            {reply, ok, progress(resolve(Id, Ready))};
        _ -> {reply, ok, State}
    end;
handle_call({ready, Id, Pid, Value}, _, State) ->
    case node(Id, State) of
        Node = #{pid := Pid, retiring := Pid} ->
            {reply, ok, put_node(Id, Node#{checkpoint := {some, Value}, scope := none}, State)};
        Node = #{pid := Pid} ->
            Ready = put_node(Id, Node#{checkpoint := {some, Value}, status := ready, restarting := false,
                restore := restart, scope := none}, State),
            {reply, ok, progress(resolve(Id, Ready))};
        _ -> {reply, ok, State}
    end;
handle_call({start_failed, Id, Pid, Cause}, _, State) ->
    case node(Id, State) of
        #{pid := Pid, removed := false} ->
            {_, Updated} = failure(Id, none, Cause, make_ref(), State),
            {reply, ok, Updated};
        _ -> {reply, ok, State}
    end;
handle_call({scope, Id, Pid, Scope}, _, State) ->
    case node(Id, State) of
        Node = #{pid := Pid, removed := false} -> {reply, ok, put_node(Id, Node#{scope := Scope}, State)};
        _ -> {reply, stopped, State}
    end;
handle_call({begin_message, Id, Pid, Token}, _, State) ->
    case node(Id, State) of
        Node = #{pid := Pid, active := Entry = #{token := Token}} ->
            {reply, true, put_node(Id, Node#{active := Entry#{begun := true}}, State)};
        _ -> {reply, false, State}
    end;
handle_call({commit, Id, Pid, Token, Reply, Value}, _, State) ->
    case node(Id, State) of
        Node = #{pid := Pid, active := Entry = #{token := Token}} ->
            reply(Entry, {ok, Reply}),
            {reply, ok, progress(put_node(Id, Node#{checkpoint := {some, Value}, active := none, scope := none}, State))};
        _ -> {reply, ok, State}
    end;
handle_call({failed, Id, Pid, Token, Cause, Origin}, _, State) ->
    case node(Id, State) of
        #{pid := Pid, active := Entry = #{token := Token}} ->
            {Action, Updated} = failure(Id, Entry, Cause, Origin, State),
            {reply, Action, progress(Updated)};
        _ -> {reply, exit, State}
    end;
handle_call({worker_stopped, Id, Pid, Token}, _, State) ->
    case node(Id, State) of
        Node = #{pid := Pid, active := Entry = #{token := Token}} ->
            Waiting = put_node(Id, Node#{active := none, status := failed,
                completion := [{Entry, {ok, ok}, none} | maps:get(completion, Node)]}, State),
            {Target, Updated} = decide(Id, normal, Waiting),
            {Action, Stopping} = trigger(Target, Id, Updated),
            {reply, Action, progress(Stopping)};
        _ -> {reply, exit, State}
    end;
handle_call({request, Id, Request}, From, State) -> request(Id, Request, From, State).

handle_cast(_, State) -> {noreply, State}.

handle_info({booted, ok}, State = #{boot := starting, starters := Waiters, public := Id}) ->
    erlang:demonitor(maps:get(owner, State), [flush]),
    lists:foreach(fun(From) -> gen_server:reply(From, {ok, handle(Id, State)}) end, Waiters),
    {noreply, State#{boot := ready, starters := [], start_delivered := Waiters =/= []}};
handle_info({booted, {error, Reason}}, State = #{starters := Waiters}) ->
    lists:foreach(fun(From) -> gen_server:reply(From, {error, Reason}) end, Waiters),
    finish_tree(abort_tree(State#{boot := {failed, Reason}, starters := [], start_delivered := Waiters =/= []}));
handle_info({'DOWN', Monitor, process, _, _}, State = #{owner := Monitor, boot := starting}) ->
    finish_tree(abort_tree(State#{boot := {failed, owner_stopped}, start_delivered := true}));
handle_info({'DOWN', Monitor, process, Pid, Reason}, State) ->
    case [Id || {Id, #{pid := P, monitor := M}} <- maps:to_list(maps:get(nodes, State)), P =:= Pid, M =:= Monitor] of
        [Id] -> finish_tree(progress(activate_claims(down(Id, Reason, State))));
        [] -> {noreply, State}
    end;
handle_info({linked_crash, Id, Cause, Origin}, State) ->
    Node = node(Id, State),
    case maps:get(accepting, Node) andalso not maps:is_key(Origin, maps:get(seen, Node)) of
        true ->
            Seen = maps:get(seen, Node),
            Entry = entry(none, {crash, Cause, Origin}),
            Updated = put_node(Id, Node#{seen := Seen#{Origin => true},
                waiting := queue:in(Entry, maps:get(waiting, Node))}, State),
            {noreply, progress(Updated)};
        false -> {noreply, State}
    end;
handle_info({stopped_supervisor, Id, Pid}, State = #{stopping := Stopping}) ->
    Next = case maps:get(Id, Stopping, none) of Pid -> maps:remove(Id, Stopping); _ -> Stopping end,
    {noreply, State#{stopping := Next}};
handle_info({shutdown_observed, Id, ParentPid}, State) ->
    Node = node(Id, State),
    case {maps:get(shutdown_wait, Node), maps:get(pid, Node), is_process_alive(ParentPid)} of
        {ParentPid, none, true} ->
            %% The parent has finished handling its exit and did not start a
            %% replacement. A normally stopped transient/temporary is gone.
            {noreply, progress(halt_subtree(Id, State))};
        _ -> {noreply, State}
    end;
handle_info(_, State) -> {noreply, State}.

terminate(_, State) ->
    %% The root is linked to this service as its OTP parent. It shuts its
    %% children down if the service dies, including an untrappable kill.
    maps:foreach(fun(_, Node) ->
        reply(maps:get(active, Node), stopped),
        lists:foreach(fun(E) -> reply(E, stopped) end, queue:to_list(maps:get(waiting, Node))),
        lists:foreach(fun({E, Result, _}) -> reply(E, Result) end, maps:get(completion, Node))
    end, maps:get(nodes, State)).

request(Id, {enqueue, call, _} = Request, From = {Caller, _}, State) ->
    case maps:get(pid, node(Id, State)) of
        Caller -> {reply, {error, actor_self_call}, State};
        _ -> enqueue(Id, Request, From, State)
    end;
request(Id, {enqueue, tell, _} = Request, From, State) -> enqueue(Id, Request, From, State);
request(Id, {observe, Observer}, _, State) ->
    Node = node(Id, State),
    {reply, {ok, ok}, put_node(Id, Node#{observers := lists:usort([Observer | maps:get(observers, Node)])}, State)};
request(Id, {link, Other}, _, State) ->
    Node = node(Id, State),
    {reply, {ok, ok}, put_node(Id, Node#{links := lists:usort([Other | maps:get(links, Node)])}, State)};
request(Id, worker_pid, _, State) -> {reply, {ok, maps:get(pid, node(Id, State))}, State};
request(Id, restart_count, _, State) -> {reply, {ok, length(maps:get(restarts, node(Id, State)))}, State};
request(Id, children, _, State) ->
    {reply, {ok, [{Name, handle(Child, State)} || {Name, Child} <- live_children(Id, State)]}, State};
request(Id, {child, Name}, _, State) ->
    case lists:keyfind(Name, 1, maps:get(children, node(Id, State))) of
        {Name, Child} -> {reply, {ok, handle(Child, State)}, State};
        false -> {reply, {error, {unknown_child, Name}}, State}
    end;
request(Id, stop, From = {Caller, _}, State) ->
    case lists:any(fun(Child) -> maps:get(pid, node(Child, State)) =:= Caller end, subtree(Id, State)) of
        true -> {reply, {error, actor_self_stop}, State};
        false -> request_stop(Id, From, State)
    end.

enqueue(Id, {enqueue, Mode, Operation}, From, State) ->
    Node = node(Id, State),
    case maps:get(kind, Node) =:= actor andalso maps:get(accepting, Node) of
        false -> {reply, stopped, State};
        true ->
            Entry = entry(case Mode of call -> From; tell -> none end, Operation),
            Updated = progress(put_node(Id, Node#{waiting := queue:in(Entry, maps:get(waiting, Node))}, State)),
            case Mode of call -> {noreply, Updated}; tell -> {reply, {ok, ok}, Updated} end
    end.

request_stop(Id, From, State) ->
    Node = node(Id, State),
    case {maps:get(kind, Node), maps:get(removed, Node), maps:get(closing, Node)} of
        {_, true, _} -> {reply, {ok, ok}, State};
        {actor, _, _} ->
            Permanent = maps:get(parent, Node) =/= none andalso maps:get(lifetime, Node) =:= permanent,
            Updated = put_node(Id, Node#{accepting := Permanent,
                waiting := queue:in(entry(From, stop), maps:get(waiting, Node))}, State),
            {noreply, progress(Updated)};
        {supervisor, _, _} ->
            Stops = maps:get(stops, State),
            Closing = close_subtree(Id, State#{stops := Stops#{Id => [From | maps:get(Id, Stops, [])]}}),
            {noreply, progress(Closing)}
    end.

allocate(Spec, Id, Parent, Lifetime, Nodes) ->
    Children = [{Name, Id ++ [Name]} || {Name, _, _} <- maps:get(children, Spec, [])],
    Node = #{kind => maps:get(kind, Spec), spec => Spec, parent => Parent, lifetime => Lifetime,
        children => Children, pid => none, monitor => none, retiring => none, status => dormant,
        checkpoint => none, restore => restart, waiting => queue:new(), active => none,
        completion => [], claim => none, scope => none,
        shutdown_wait => none,
        accepting => true, removed => false, restarting => false, closing => false,
        observers => [], links => [], seen => #{}, restarts => [], stop_notified => false},
    lists:foldl(fun({Name, Life, Child}, Acc) -> allocate(Child, Id ++ [Name], Id, Life, Acc) end,
        Nodes#{Id => Node}, maps:get(children, Spec, [])).

node(Id, State) -> maps:get(Id, maps:get(nodes, State)).
put_node(Id, Node, State) -> State#{nodes := (maps:get(nodes, State))#{Id := Node}}.
eligible(Node) -> not maps:get(removed, Node) andalso not maps:get(closing, Node).
handle(Id, State) ->
    Kind = case maps:get(kind, node(Id, State)) of actor -> lawspec_actor; supervisor -> lawspec_supervisor end,
    {Kind, maps:get(tree, State), Id}.
live_children(Id, State) -> [{Name, Child} || {Name, Child} <- maps:get(children, node(Id, State)),
    not maps:get(removed, node(Child, State))].
child_specs(Id, State) -> [lawspec_beam_actor_sup:child_spec(maps:get(tree, State), Child,
    maps:get(lifetime, node(Child, State)), maps:get(kind, node(Child, State))) || {_, Child} <- live_children(Id, State)].

register_pid(Id, Pid, State) ->
    Node = node(Id, State),
    case maps:get(monitor, Node) of none -> ok; Monitor -> erlang:demonitor(Monitor, [flush]) end,
    put_node(Id, Node#{pid := Pid, monitor := erlang:monitor(process, Pid), retiring := none, status := starting}, State).

%% A killed supervisor can be replaced before its old children finish. Hold
%% replacement init until the previous worker's DOWN has been observed, so a
%% still-running handler can commit once and no two generations share a state.
claim(Id, Pid, From, State) ->
    Node = node(Id, State),
    case maps:get(claim, Node) of none -> ok; {_, Previous} -> gen_server:reply(Previous, stopped) end,
    Claimed = put_node(Id, Node#{claim := {Pid, From}}, State),
    {noreply, activate_claims(Claimed)}.

activate_claims(State) ->
    %% A sibling's shutdown can be observed before the original child's
    %% failure. Account for every already-dead process before starting any
    %% replacement, including the first child in a one_for_all restart.
    PendingDown = lists:any(fun(Node) -> case maps:get(pid, Node) of
        none -> false;
        Pid -> not is_process_alive(Pid)
    end end, maps:values(maps:get(nodes, State))),
    case PendingDown of
        true -> State;
        false -> lists:foldl(fun(Id, Acc) -> case maps:get(pid, node(Id, Acc)) of
            none -> activate_claim(Id, Acc);
            _ -> Acc
        end end, State, maps:keys(maps:get(nodes, State)))
    end.

activate_claim(Id, State) ->
    Node = node(Id, State),
    case {maps:get(claim, Node), maps:get(shutdown_wait, Node)} of
        {none, _} -> State;
        {{_, _}, Waiting} when Waiting =/= none ->
            %% OTP selected a replacement for a direct shutdown of a
            %% permanent child. A group restart clears this flag as a unit.
            {Target, Decided} = decide(Id, normal, put_node(Id, Node#{shutdown_wait := none}, State)),
            Planned = case Target of Id -> Decided;
                _ -> stop_supervisor(Target, {lawspec_restart_limit, Target}, Decided)
            end,
            activate_claim(Id, Planned);
        {{Pid, From}, none} ->
            Cleared = put_node(Id, Node#{claim := none}, State),
            case {maps:get(removed, Node), is_process_alive(Pid)} of
                {true, _} -> gen_server:reply(From, stopped), Cleared;
                {_, false} -> Cleared;
                {false, true} ->
                    Registered = register_pid(Id, Pid, Cleared),
                    case maps:get(kind, Node) of
                        actor ->
                            Checkpoint = case {maps:get(restore, Node), maps:get(checkpoint, Node)} of
                                {resume, {some, Value}} -> {resume, Value};
                                {_, Previous} -> Previous
                            end,
                            gen_server:reply(From, {ok, maps:get(spec, Node), Checkpoint}),
                            Registered;
                        supervisor ->
                            Starting = put_node(Id, (node(Id, Registered))#{restarts := []}, Registered),
                            gen_server:reply(From, {ok, maps:get(spec, Node), child_specs(Id, Starting)}),
                            Starting
                    end
            end
    end.

entry(From, Operation) -> #{from => From, operation => Operation, token => make_ref(), begun => false}.
reply(none, _) -> ok;
reply(#{from := none}, _) -> ok;
reply(#{from := From}, Result) -> gen_server:reply(From, Result).

progress(Initial) ->
    State = maybe_close_standalone(Initial),
    Dispatched = maps:fold(fun(Id, Node, Acc) ->
        case {maps:get(kind, Node), maps:get(status, Node), maps:get(restarting, Node), maps:get(active, Node)} of
            {actor, ready, false, none} ->
                case queue:out(maps:get(waiting, Node)) of
                    {empty, _} -> Acc;
                    {{value, Entry}, Rest} ->
                        maps:get(pid, Node) ! {deliver, maps:get(token, Entry), maps:get(operation, Entry)},
                        put_node(Id, Node#{active := Entry, waiting := Rest}, Acc)
                end;
            _ -> Acc
        end
    end, State, maps:get(nodes, State)),
    ReadyStops = [Id || {Id, #{kind := supervisor, closing := true, pid := Pid}} <- maps:to_list(maps:get(nodes, Dispatched)),
        is_pid(Pid), not maps:is_key(Id, maps:get(stopping, Dispatched)),
        not parent_closing(Id, Dispatched), idle_subtree(Id, Dispatched)],
    finish_ready_stops(lists:foldl(fun begin_stop/2, Dispatched, ReadyStops)).

begin_stop(Id, State) ->
    Node = node(Id, State),
    case maps:get(parent, Node) =/= none andalso maps:get(lifetime, Node) =:= permanent of
        false -> stop_supervisor(Id, normal, State);
        true ->
            Reopened = map_subtree(Id, fun(N) -> N#{closing := false, accepting := not maps:get(removed, N)} end, State),
            {Target, Decided} = decide(Id, normal, Reopened),
            Reason = case Target of Id -> normal; _ -> {lawspec_restart_limit, Target} end,
            stop_supervisor(Target, Reason, Decided)
    end.

failure(Id, Entry, Cause, Origin, State) ->
    Node = node(Id, State),
    Result = case Entry of #{operation := {crash, _, _}} -> {ok, ok}; _ -> {crashed, Cause} end,
    Seen = maps:get(seen, Node),
    Failed = put_node(Id, Node#{active := none, status := failed, seen := Seen#{Origin => true}, scope := none,
        completion := maps:get(completion, Node) ++ [{Entry, Result, {crashed, Cause, Origin}}]}, State),
    {Target, Updated} = decide(Id, abnormal, Failed),
    trigger(Target, Id, Updated).

%% Exact rolling restart budgets, including escalation. A failing worker is
%% held alive when its supervisor must fail: this lets OTP stop the whole
%% subtree before its parent starts the replacement supervisor.
decide(Id, Termination, State) -> decide(Id, Termination, Id, State).
decide(Id, Termination, Origin, State) ->
    Node = node(Id, State),
    Restart = eligible(Node) andalso (maps:get(lifetime, Node) =:= permanent orelse
        (maps:get(lifetime, Node) =:= transient andalso Termination =:= abnormal)),
    case {maps:get(parent, Node), Restart} of
        {none, _} -> {Id, terminal_failure(Id, Termination, State)};
        {_, false} -> {Id, terminal_failure(Id, Termination, State)};
        {Parent, true} ->
            Supervisor = node(Parent, State),
            Spec = maps:get(spec, Supervisor),
            Now = erlang:monotonic_time(microsecond),
            Recent = [T || T <- maps:get(restarts, Supervisor), Now - T =< maps:get(period, Spec)],
            case length(Recent) < maps:get(restarts, Spec) andalso eligible(Supervisor) of
                true ->
                    Charged = put_node(Parent, Supervisor#{restarts := Recent ++ [Now]}, State),
                    {Id, restart_group(Parent, Id, Origin, Charged)};
                false -> decide(Parent, abnormal, Origin, State)
            end
    end.

%% OTP replaces sibling processes immediately, but LawSpec's logical sibling
%% restart belongs after every message already accepted at the time of the
%% crash. A replacement resumes its checkpoint and drains that prefix before
%% executing the restart entry; the failed actor itself restarts during init.
%% Carry the original actor through escalation so the same order holds when
%% an ancestor supervisor, and therefore its entire subtree, is replaced.
restart_group(Parent, Failed, Origin, State) ->
    Children = [Id || {_, Id} <- live_children(Parent, State)],
    Group = case maps:get(strategy, maps:get(spec, node(Parent, State))) of
        one_for_one -> [Failed];
        one_for_all -> Children;
        rest_for_one -> lists:dropwhile(fun(Id) -> Id =/= Failed end, Children)
    end,
    lists:foldl(fun(Id, Acc) ->
        case maps:get(lifetime, node(Id, Acc)) of
            temporary -> halt_subtree(Id, Acc);
            _ -> lists:foldl(fun(Child, Updated) ->
                Node = node(Child, Updated),
                case maps:get(removed, Node) of
                    true -> Updated;
                    false ->
                        Restarting = Node#{restarting := true, retiring := maps:get(pid, Node), closing := false,
                            accepting := true, shutdown_wait := none},
                        Next = case maps:get(kind, Node) =:= actor andalso Child =/= Origin of
                            true -> Restarting#{restore := resume,
                                waiting := queue:in(entry(none, restart), maps:get(waiting, Node))};
                            false -> Restarting#{restore := restart}
                        end,
                        put_node(Child, Next, Updated)
                end
            end, Acc, subtree(Id, Acc))
        end
    end, State, Group).

trigger(Id, Id, State) -> {exit, State};
trigger(Target, _, State) -> {wait, stop_supervisor(Target, {lawspec_restart_limit, Target}, State)}.

stop_supervisor(Id, Reason, State = #{stopping := Stopping}) ->
    Pid = maps:get(pid, node(Id, State)),
    case maps:get(Id, Stopping, none) =:= Pid of
        true -> State;
        false ->
            Tree = self(),
            spawn(fun() ->
                try gen_server:stop(Pid, Reason, infinity) catch exit:_ -> ok end,
                Tree ! {stopped_supervisor, Id, Pid}
            end),
            State#{stopping := Stopping#{Id => Pid}}
    end.

down(Id, Reason, State) ->
    Node = node(Id, State),
    close_scope(Node),
    Cleared = put_node(Id, Node#{pid := none, monitor := none, scope := none}, State#{stopping := maps:remove(Id, maps:get(stopping, State))}),
    Retiring = maps:get(restarting, Node) andalso maps:get(retiring, Node) =:= maps:get(pid, Node),
    case {Id, maps:get(removed, Node), maps:get(closing, Node), Retiring, maps:get(status, Node)} of
        {[], Removed, Closing, _, _} ->
            maps:foreach(fun(_, N) -> close_scope(N) end, maps:get(nodes, Cleared)),
            Termination = case Removed orelse Closing orelse normal_exit(Reason) of
                true -> normal; false -> {abnormal, {exit, Reason, []}}
            end,
            finish_stops([], terminal_failure([], Termination, Cleared));
        {_, true, _, _, _} -> maybe_close_standalone(finish_stops(Id, Cleared));
        {_, _, true, _, _} ->
            finish_stops(Id, halt_subtree(Id, Cleared));
        {_, _, _, true, _} -> interrupted(Id, Reason, Cleared);
        {_, _, _, _, failed} -> Cleared;
        {_, _, _, _, _} when Reason =:= shutdown -> passive_shutdown(Id, Reason, Cleared);
        _ ->
            Interrupted = interrupted(Id, Reason, Cleared),
            case ancestor_dead(Id, Interrupted) of
                true ->
                    WaitingNode = node(Id, Interrupted),
                    put_node(Id, WaitingNode#{restarting := true}, Interrupted);
                false -> unexpected_down(Id, Reason, Interrupted)
            end
    end.

passive_shutdown(Id, Reason, State) ->
    Interrupted = interrupted(Id, Reason, State),
    Node = node(Id, Interrupted), Parent = maps:get(parent, Node),
    ParentPid = maps:get(pid, node(Parent, Interrupted)),
    case ParentPid of
        none -> put_node(Id, Node#{restarting := true}, Interrupted);
        _ ->
            %% Never wait for a busy supervisor inside the mailbox service:
            %% that supervisor may itself be starting a child which needs us.
            Tree = self(),
            spawn(fun() ->
                try supervisor:which_children(ParentPid) catch exit:_ -> ok end,
                Tree ! {shutdown_observed, Id, ParentPid}
            end),
            put_node(Id, Node#{restarting := true, shutdown_wait := ParentPid}, Interrupted)
    end.

normal_exit(normal) -> true;
normal_exit(shutdown) -> true;
normal_exit({shutdown, _}) -> true;
normal_exit(_) -> false.

ancestor_dead(Id, State) -> case maps:get(parent, node(Id, State)) of
    none -> false;
    Parent -> case maps:get(pid, node(Parent, State)) of
        none -> true;
        Pid -> not is_process_alive(Pid) orelse ancestor_dead(Parent, State)
    end
end.

unexpected_down(Id, Reason, State) ->
    Node = node(Id, State),
    Normal = normal_exit(Reason),
    Observed = case maps:get(completion, Node) =:= [] andalso not Normal of
        true -> put_node(Id, Node#{completion :=
            [{none, {crashed, {exit, Reason, []}}, {crashed, {exit, Reason, []}, make_ref()}}]}, State);
        false -> State
    end,
    {Target, Planned} = decide(Id, case Normal of true -> normal; false -> abnormal end, Observed),
    case Target of Id -> Planned; _ -> stop_supervisor(Target, {lawspec_restart_limit, Target}, Planned) end.

interrupted(Id, Reason, State) ->
    Node = node(Id, State),
    case maps:get(active, Node) of
        none -> put_node(Id, Node#{status := dormant}, State);
        Entry = #{begun := false} -> put_node(Id, Node#{active := none, status := dormant,
            waiting := queue:in_r(Entry, maps:get(waiting, Node))}, State);
        Entry ->
            Cause = {exit, Reason, []},
            put_node(Id, Node#{active := none, status := dormant,
                completion := maps:get(completion, Node) ++ [{Entry, {crashed, Cause}, {crashed, Cause, make_ref()}}]}, State)
    end.

resolve(Id, State) ->
    Node = node(Id, State),
    lists:foreach(fun({Entry, Result, Event}) ->
        reply(Entry, Result),
        case Event of
            none -> ok;
            {crashed, Cause, Origin} ->
                notify(Id, {crashed, Cause}, State),
                lists:foreach(fun({lawspec_actor, Tree, Other}) ->
                    Tree ! {linked_crash, Other, Cause, Origin}
                end, maps:get(links, Node))
        end
    end, maps:get(completion, Node)),
    Seen = lists:foldl(fun({_, _, Event}, Acc) -> case Event of
        {crashed, _, Origin} -> Acc#{Origin => true};
        none -> Acc
    end end, maps:get(seen, Node), maps:get(completion, Node)),
    put_node(Id, Node#{completion := [], seen := Seen}, State).

notify(Id, Event, State) ->
    Tag = case maps:get(kind, node(Id, State)) of actor -> lawspec_actor_event; supervisor -> lawspec_supervisor_event end,
    lists:foreach(fun(Pid) -> Pid ! {Tag, handle(Id, State), Event} end, maps:get(observers, node(Id, State))).

map_subtree(Id, Fun, State) ->
    lists:foldl(fun(Child, Acc) -> put_node(Child, Fun(node(Child, Acc)), Acc) end,
        State, subtree(Id, State)).
subtree(Id, State) -> [Id | lists:append([subtree(Child, State) || {_, Child} <- maps:get(children, node(Id, State))])].
idle_subtree(Id, State) -> lists:all(fun(Child) ->
    Node = node(Child, State), maps:get(active, Node) =:= none andalso queue:is_empty(maps:get(waiting, Node))
end, subtree(Id, State)).
close_subtree(Id, State) -> map_subtree(Id, fun(Node) -> Node#{closing := true, accepting := false} end, State).
parent_closing(Id, State) -> case maps:get(parent, node(Id, State)) of
    none -> false;
    Parent -> maps:get(closing, node(Parent, State))
end.

terminal_failure(Id, Termination, State) ->
    Node = node(Id, State),
    case maps:get(kind, Node) =:= supervisor andalso Termination =/= normal of
        true ->
            Cause = case Termination of abnormal -> {restart_limit, Id}; {abnormal, Why} -> Why end,
            notify(Id, {crashed, Cause}, State),
            halt_subtree(Id, put_node(Id, Node#{stop_notified := true}, State));
        false -> halt_subtree(Id, State)
    end.

halt_subtree(Id, State) ->
    lists:foldl(fun(Child, Acc) ->
        Node = node(Child, Acc),
        HadCrash = lists:any(fun({_, _, E}) -> E =/= none end, maps:get(completion, Node)),
        Resolved = resolve(Child, Acc),
        case maps:get(claim, Node) of none -> ok; {_, From} -> gen_server:reply(From, stopped) end,
        reply(maps:get(active, Node), stopped),
        lists:foreach(fun(E) -> reply(E, stopped) end, queue:to_list(maps:get(waiting, Node))),
        case not maps:get(stop_notified, Node) andalso not HadCrash of
            true -> notify(Child, {stopped, none}, Resolved);
            false -> ok
        end,
        put_node(Child, (node(Child, Resolved))#{removed := true, accepting := false,
            restarting := false, status := stopped, active := none, waiting := queue:new(), claim := none,
            shutdown_wait := none, stop_notified := true}, Resolved)
    end, State, lists:reverse(subtree(Id, State))).

finish_stops(Id, State = #{stops := Stops}) ->
    lists:foreach(fun(From) -> gen_server:reply(From, {ok, ok}) end, maps:get(Id, Stops, [])),
    State#{stops := maps:remove(Id, Stops)}.
finish_ready_stops(State) ->
    lists:foldl(fun(Id, Acc) ->
        Node = node(Id, Acc),
        Ready = not maps:get(closing, Node) andalso lists:all(fun(Child) ->
            N = node(Child, Acc),
            maps:get(removed, N) orelse (maps:get(status, N) =:= ready andalso
                not maps:get(restarting, N) andalso not pending_restart(N))
        end, subtree(Id, Acc)),
        case Ready of true -> finish_stops(Id, Acc); false -> Acc end
    end, State, maps:keys(maps:get(stops, State))).
pending_restart(Node) ->
    lists:any(fun(Entry) -> case Entry of #{operation := restart} -> true; _ -> false end end,
        [maps:get(active, Node) | queue:to_list(maps:get(waiting, Node))]).
maybe_close_standalone(State = #{standalone := true, public := Id}) ->
    case maps:get(removed, node(Id, State)) of true -> close_subtree([], State); false -> State end;
maybe_close_standalone(State) -> State.
finish_tree(State) ->
    case maps:get(pid, node([], State)) of
        none -> case maps:get(start_delivered, State) of
            true -> {stop, normal, State};
            false -> {noreply, State}
        end;
        _ -> {noreply, State}
    end.
abort_tree(State) ->
    %% A start callback may not have returned to OTP yet. Cancelling startup
    %% must release that init handshake before asking the supervisor to stop.
    maps:foreach(fun(_, Node) -> case Node of
        #{kind := actor, status := starting, pid := Pid} when is_pid(Pid) -> exit(Pid, kill);
        _ -> ok
    end end, maps:get(nodes, State)),
    stop_supervisor([], shutdown, halt_subtree([], State)).

close_scope(Node) -> case maps:get(scope, Node) of
    none -> ok;
    Scope -> lawspec_beam_tasks:close(Scope)
end.
