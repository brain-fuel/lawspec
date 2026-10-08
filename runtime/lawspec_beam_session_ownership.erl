%% @doc Queue custody forms a forest. A serialized graph rejects cycles
%% without calling a channel from another channel's server. It retains only
%% process identities and ends when the last registered channel leaves.
%% ref:DEC-sessions-by-construction
-module(lawspec_beam_session_ownership).
-behaviour(gen_server).
-export([register/1, move/3, release/2, unregister/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

register(Channel) ->
    Graph = case gen_server:start({local, ?MODULE}, ?MODULE, [], []) of
        {ok, Pid} -> Pid;
        {error, {already_started, Pid}} -> Pid
    end,
    try gen_server:call(Graph, {register, Channel}, infinity) of ok -> Graph
    catch exit:{noproc, _} -> register(Channel); exit:{normal, _} -> register(Channel) end.
move(Graph, Child, Parent) -> gen_server:call(Graph, {move, Child, Parent}, infinity).
release(Graph, Channel) -> gen_server:call(Graph, {release, Channel}, infinity).
unregister(Graph, Channel) ->
    try gen_server:call(Graph, {unregister, Channel}, infinity) catch exit:_ -> ok end.
init([]) -> {ok, #{channels => #{}, monitors => #{}, parents => #{}}, 1000}.
handle_call({register, Channel}, _, State = #{channels := Channels, monitors := Monitors}) ->
    Ref = monitor(process, Channel),
    {reply, ok, State#{channels := Channels#{Channel => Ref}, monitors := Monitors#{Ref => Channel}}};
handle_call({move, Child, Parent}, _, State = #{channels := Channels, parents := Parents}) ->
    case maps:is_key(Child, Channels) andalso maps:is_key(Parent, Channels) andalso is_process_alive(Parent) of
        false -> {reply, {error, closed}, State};
        true -> case reaches(Parent, Child, Parents) of
            true -> {reply, {error, cyclic_delegation}, State};
            false -> {reply, ok, State#{parents := Parents#{Child => Parent}}}
        end
    end;
handle_call({release, Channel}, _, State = #{parents := Parents}) ->
    {reply, ok, State#{parents := maps:remove(Channel, Parents)}};
handle_call({unregister, Channel}, _, State) ->
    Next = remove(Channel, State), {reply, ok, Next, idle(Next)}.
handle_cast(_, State) -> {noreply, State, idle(State)}.
handle_info({'DOWN', Ref, process, _, _}, State = #{monitors := Monitors}) ->
    Next = case maps:find(Ref, Monitors) of {ok, Channel} -> remove(Channel, State); error -> State end,
    {noreply, Next, idle(Next)};
handle_info(timeout, State = #{channels := Channels}) when map_size(Channels) =:= 0 -> {stop, normal, State};
handle_info(_, State) -> {noreply, State, idle(State)}.
idle(#{channels := Channels}) when map_size(Channels) =:= 0 -> 0;
idle(_) -> infinity.
reaches(Child, Child, _) -> true;
reaches(Node, Child, Parents) -> case maps:find(Node, Parents) of
    error -> false;
    {ok, Parent} -> reaches(Parent, Child, Parents)
end.
remove(Channel, State = #{channels := Channels, monitors := Monitors, parents := Parents}) ->
    case maps:take(Channel, Channels) of
        error -> State;
        {Ref, Rest} ->
            demonitor(Ref, [flush]),
            State#{channels := Rest, monitors := maps:remove(Ref, Monitors),
                parents := maps:filter(fun(C, P) -> C =/= Channel andalso P =/= Channel end, Parents)}
    end.
