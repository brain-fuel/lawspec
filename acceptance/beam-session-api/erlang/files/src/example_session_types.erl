%% ref:DEC-tests-cite-requirements ref:DEC-sessions-by-construction
-module(example_session_types).
-export([native_probe/1]).
-define(E, lawspec_session_example_session_types_exchange).
-define(S, lawspec_session_example_session_types_symbols).
-define(Z, lawspec_session_example_session_types_empty).

native_probe(ok) ->
    ?E:with_pair(fun(First, Second) ->
        Task = ?E:spawn_second(Second, fun(End) ->
            {{just, [1, 2, 3]}, Next} = ?E:second_receive_0(End),
            _ = ?E:second_send_1(Next, ok), ok
        end),
        Next = ?E:first_send_0(First, {just, [1, 2, 3]}),
        {ok, _} = ?E:first_receive_1(Next), ok = lawspec_beam_session_task:join(Task)
    end),
    ?S:with_pair(fun(First, Second) ->
        Identity = lawspec_beam_scalar:new_symbol(<<"session">>),
        _ = ?S:first_send_0(First, Identity), {Identity, _} = ?S:second_receive_0(Second)
    end),
    ?Z:with_pair(fun(_, _) -> true end).
