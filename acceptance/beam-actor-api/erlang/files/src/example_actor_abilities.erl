%% ref:DEC-tests-cite-requirements ref:DEC-actors-otp-supervision
-module(example_actor_abilities).
-export([open_counter/1, add/3, total/1, clear/1, echo/2, reopen/2, factor_handler/0, restore_handler/0, native_probe/1, remote_probe/1]).

factor_handler() -> #{adjust => fun(N) -> 2 * N end}.
restore_handler() -> #{restore => fun(N) -> N + 10 end}.
open_counter(ok) -> {counter, 0}.
add(Factor, {counter, N}, Amount) ->
    Next = N + (maps:get(adjust, Factor))(Amount), {pair, Next, {counter, Next}}.
total({counter, N} = State) -> {pair, N, State}.
clear(_) -> {counter, 0}.
echo(State, Value) -> {pair, Value, State}.
reopen(Restore, {counter, N}) -> {counter, (maps:get(restore, Restore))(N)}.

native_probe(ok) ->
    lawspec_supervisor_example_actor_abilities_root:with_supervisor(factor_handler(), restore_handler(), fun(Root) ->
        Bank = lawspec_supervisor_example_actor_abilities_root:bank(Root),
        Actor = lawspec_supervisor_example_actor_abilities_bank:counter(Bank),
        14 = lawspec_actor_example_actor_abilities_counter:add(Actor, 7),
        lawspec_actor_example_actor_abilities_counter:crash(Actor),
        24 = lawspec_actor_example_actor_abilities_counter:total(Actor),
        lawspec_actor_example_actor_abilities_counter:tell_add(Actor, 3),
        30 = lawspec_actor_example_actor_abilities_counter:total(Actor),
        lawspec_supervisor_example_actor_abilities_bank:stop(Bank),
        40 = lawspec_actor_example_actor_abilities_counter:total(Actor),
        true
    end).

remote_probe(ok) ->
    beam_remote_probe:with_nodes(fun(A, B) ->
        lawspec_supervisor_example_actor_abilities_root:with_supervisor(
            #{adjust => fun(N) -> 3 * N end}, restore_handler(), fun(Root) ->
            Bank = lawspec_supervisor_example_actor_abilities_root:bank(Root),
            Actor = lawspec_supervisor_example_actor_abilities_bank:counter(Bank),
            Address = lawspec_actor_example_actor_abilities_counter:serve(Actor, B, <<"counter">>),
            Remote = lawspec_actor_example_actor_abilities_counter_remote:connect(A, Address),
            21 = lawspec_actor_example_actor_abilities_counter_remote:add(Remote, 7),
            21 = lawspec_actor_example_actor_abilities_counter_remote:total(Remote),
            lawspec_actor_example_actor_abilities_counter:crash(Actor),
            31 = lawspec_actor_example_actor_abilities_counter_remote:total(Remote),
            lawspec_supervisor_example_actor_abilities_bank:stop(Bank),
            41 = lawspec_actor_example_actor_abilities_counter_remote:total(Remote),
            Fast = lawspec_actor_example_actor_abilities_counter_remote:connect_with_timeout(A, Address, 1000),
            {just, [0, -7]} = lawspec_actor_example_actor_abilities_counter_remote:echo(Fast, {just, [0, -7]}),
            ok = lawspec_actor_example_actor_abilities_counter_remote:clear(Fast),
            0 = lawspec_actor_example_actor_abilities_counter_remote:total(Remote),
            lawspec_beam_node:stop(B),
            0 = lawspec_actor_example_actor_abilities_counter:total(Actor),
            true
        end)
    end).
