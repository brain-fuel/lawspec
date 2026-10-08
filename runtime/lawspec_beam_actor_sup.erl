%% @doc The actual OTP supervision tree. The stable mailbox service retains
%% checkpoints across replacement of both workers and nested supervisors.
%% ref:DEC-actors-otp-supervision ref:erlang-otp-supervisors
-module(lawspec_beam_actor_sup).
-behaviour(supervisor).
-export([start_root/2, start_link/2, start_actor/2, child_spec/4]).
-export([init/1]).

start_root(Tree, Spec) -> supervisor:start_link(?MODULE, {root, Tree, Spec}).
start_link(Tree, Id) ->
    case supervisor:start_link(?MODULE, {nested, Tree, Id}) of
        {ok, Pid} = Result ->
            ok = gen_server:call(Tree, {supervisor_ready, Id, Pid}, infinity),
            Result;
        Other -> Other
    end.

start_actor(Tree, Id) ->
    case gen_server:call(Tree, {eligible, Id}, infinity) of
        true -> lawspec_beam_actor:start_link(Tree, Id);
        false -> ignore
    end.

child_spec(Tree, Id, Lifetime, Kind) ->
    Function = case Kind of actor -> start_actor; supervisor -> start_link end,
    #{id => Id, start => {?MODULE, Function, [Tree, Id]}, restart => Lifetime,
        shutdown => case Kind of actor -> 5000; supervisor -> infinity end,
        type => case Kind of actor -> worker; supervisor -> supervisor end,
        modules => [case Kind of actor -> lawspec_beam_actor; supervisor -> ?MODULE end]}.

init({root, _, Spec}) -> {ok, {flags(Spec), []}};
init({nested, Tree, Id}) ->
    case gen_server:call(Tree, {supervisor_started, Id, self()}, infinity) of
        {ok, Spec, Children} -> {ok, {flags(Spec), Children}};
        stopped -> ignore
    end.

flags(Spec) ->
    %% OTP's intensity window is measured in whole seconds. LawSpec permits
    %% microsecond windows, so the mailbox service applies its exact rolling
    %% budget before releasing a failure to OTP. OTP performs all child
    %% termination, strategy ordering, lifetime decisions and replacements.
    %% A one-second OTP window can span almost two real seconds because its
    %% timestamps are whole seconds. Bound all the exact windows it can
    %% contain, with room for the final failed attempt that stops the tree.
    Windows = 2000000 div maps:get(period, Spec, 5000000) + 1,
    Intensity = max(1, maps:get(restarts, Spec, 3) * Windows + 1),
    #{strategy => maps:get(strategy, Spec, one_for_one),
        intensity => Intensity, period => 1}.
