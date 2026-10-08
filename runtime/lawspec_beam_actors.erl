%% @doc Stable actor handles backed by gen_server workers and OTP supervisors.
%% Handles name mailboxes, not worker pids: a supervised restart replaces the
%% worker without losing its committed checkpoint or waiting messages.
%% ref:DEC-actors-otp-supervision ref:erlang-otp-supervisors
-module(lawspec_beam_actors).
-export([start/1, start/2, start_supervisor/1, actor/2, supervisor/4,
    call/2, tell/2, state/1, crash/1, crash/2, stop/1, monitor/2, link/2,
    child/2, children/1, worker_pid/1, restart_count/1, context/0]).
-export_type([actor/0, supervisor/0, event/0]).
-opaque actor() :: {lawspec_actor, pid(), [term()]}.
-opaque supervisor() :: {lawspec_supervisor, pid(), [term()]}.
-type event() :: {crashed, term()} | {stopped, none}.

-spec start(fun(() -> State)) -> actor() when State :: term().
-spec start(fun(() -> State), fun((State) -> State)) -> actor().
-spec call(actor(), fun((State) -> {Reply, State})) -> Reply.
-spec tell(actor(), fun((State) -> {term(), State})) -> ok.
-spec stop(actor() | supervisor()) -> ok.
-spec monitor(actor() | supervisor(), pid()) -> ok.

start(Start) -> start(Start, fun(_) -> Start() end).
start(Start, Restart) -> lawspec_beam_actor_tree:start(actor(Start, Restart)).
start_supervisor(Spec = #{kind := supervisor}) -> lawspec_beam_actor_tree:start(Spec).

actor(Start, Restart) when is_function(Start, 0), is_function(Restart, 1) ->
    #{kind => actor, start => Start, restart => Restart, context => context()}.

supervisor(Strategy, Restarts, Period, Children)
        when is_integer(Restarts), Restarts >= 0, is_integer(Period), Period > 0 ->
    true = lists:member(Strategy, [one_for_one, one_for_all, rest_for_one]),
    Names = [Name || {Name, _, _} <- Children],
    true = length(Names) =:= length(lists:usort(Names)),
    lists:foreach(fun({_, Lifetime, _}) ->
        true = lists:member(Lifetime, [permanent, transient, temporary])
    end, Children),
    #{kind => supervisor, strategy => Strategy, restarts => Restarts,
        period => Period, children => Children}.

call(Actor, Handler) when is_function(Handler, 1) ->
    request(Actor, {enqueue, call, {handler, Handler, context()}}).
tell(Actor, Handler) when is_function(Handler, 1) ->
    request(Actor, {enqueue, tell, {handler, Handler, context()}}).
state(Actor) -> call(Actor, fun(State) -> {State, State} end).
crash(Actor) -> crash(Actor, crashed_on_purpose).
crash(Actor, Cause) -> request(Actor, {enqueue, call, {crash, Cause, make_ref()}}).
stop(Handle) ->
    try request(Handle, stop)
    catch error:{lawspec, actor_stopped} -> ok end.
monitor(Handle, Observer) when is_pid(Observer) -> request(Handle, {observe, Observer}).
link(Left = {lawspec_actor, _, _}, Right = {lawspec_actor, _, _}) ->
    ok = request(Left, {link, Right}),
    request(Right, {link, Left}).
child(Supervisor, Name) -> request(Supervisor, {child, Name}).
children(Supervisor) -> request(Supervisor, children).
worker_pid(Handle) -> request(Handle, worker_pid).
restart_count(Supervisor) -> request(Supervisor, restart_count).

%% Actors outlive their callers and queued tells still run when their sender
%% exits. A caller's task cancellation scope must not own a persistent actor.
context() -> lists:keydelete({lawspec_beam_tasks, scopes}, 1,
    lawspec_beam_runtime:worker_context()).

request({Kind, Tree, Id}, Request) when Kind =:= lawspec_actor; Kind =:= lawspec_supervisor ->
    Result = try gen_server:call(Tree, {request, Id, Request}, infinity)
        catch exit:{_, {gen_server, call, [Tree, _, infinity]}} -> stopped end,
    case Result of
        {ok, Value} -> Value;
        {crashed, Cause} -> error({lawspec, {actor_crashed, Cause}});
        stopped -> error({lawspec, actor_stopped});
        {error, Reason} -> error({lawspec, Reason})
    end.
