%% ref:DEC-tests-cite-requirements ref:DEC-actors-otp-supervision
-module(example_actor_abilities).
-export([open_counter/1, add/3, total/1, reopen/2, factor_handler/0, restore_handler/0, native_probe/1]).

factor_handler() -> #{adjust => fun(N) -> 2 * N end}.
restore_handler() -> #{restore => fun(N) -> N + 10 end}.
open_counter(ok) -> {counter, 0}.
add(Factor, {counter, N}, Amount) ->
    Next = N + (maps:get(adjust, Factor))(Amount), {pair, Next, {counter, Next}}.
total({counter, N} = State) -> {pair, N, State}.
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
