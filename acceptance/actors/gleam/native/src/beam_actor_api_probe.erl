%% Native OTP application fixture; no property framework dependency.
%% ref:DEC-tests-cite-requirements ref:DEC-actors-otp-supervision
-module(beam_actor_api_probe).
-behaviour(supervisor).
-export([with_parent/2, child/1, round_trip/1, is_nil/1, probe/0, init/1]).

is_nil(Value) -> Value =:= nil.

init(Child) -> {ok, {#{strategy => one_for_one}, [Child]}}.
with_parent(Child, Body) ->
    {ok, Parent} = supervisor:start_link(?MODULE, Child),
    unlink(Parent),
    try Body(Parent) after gen_server:stop(Parent, normal, infinity) end.
child(Parent) ->
    [{_, Service, worker, _}] = supervisor:which_children(Parent), Service.
round_trip(Actor) ->
    Schema = lawspec_data:schema(make_ref()), Type = {<<"example.actors::type::AccountActor">>, []},
    Logical = lawspec_beam_schema:from_native(Actor, Type, Schema),
    lawspec_beam_schema:to_native(Logical, Type, Schema).

probe() ->
    with_parent(lawspec_supervisor_example_actors_bank:child_spec([]), fun(Parent) ->
        Bank = lawspec_supervisor_example_actors_bank:from_process(child(Parent)),
        A = lawspec_supervisor_example_actors_bank:account(Bank),
        A = round_trip(A),
        lawspec_actor_example_actors_account:monitor(A, self()),
        Old = lawspec_actor_example_actors_account:worker_pid(A),
        5 = lawspec_actor_example_actors_account:deposit(A, 5),
        lawspec_actor_example_actors_account:tell_deposit(A, 3),
        8 = lawspec_actor_example_actors_account:balance(A),
        lawspec_actor_example_actors_account:crash(A),
        {ok, {crashed, _}} = lawspec_beam_actors:receive_event(A, 1000),
        8 = lawspec_actor_example_actors_account:balance(A),
        false = (Old =:= lawspec_actor_example_actors_account:worker_pid(A)),
        8 = lawspec_actor_example_actors_account:withdraw_all(A),
        lawspec_actor_example_actors_account:close(A),
        lawspec_actor_example_actors_account:tell_close(A),
        0 = lawspec_actor_example_actors_account:balance(A),
        true
    end).
