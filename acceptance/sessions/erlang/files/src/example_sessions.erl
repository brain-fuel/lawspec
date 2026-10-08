%% ref:DEC-tests-cite-requirements ref:DEC-sessions-by-construction
-module(example_sessions).
-export([add/2, add_hired/2]).
-define(S, lawspec_session_example_sessions_serve).
-define(H, lawspec_session_example_sessions_hire).

serve(Server) ->
    {A, S1} = ?S:first_receive_0(Server),
    {B, S2} = ?S:first_receive_1(S1),
    _ = ?S:first_send_2(S2, A + B), ok.
ask(Client, A, B) ->
    C1 = ?S:second_send_0(Client, A), C2 = ?S:second_send_1(C1, B),
    {Total, _} = ?S:second_receive_2(C2), Total.
manage(Manager) -> {Server, _} = ?H:second_receive_0(Manager), serve(Server).

add(A, B) ->
    ?S:with_pair(fun(Server, Client) ->
        Task = ?S:spawn_first(Server, fun serve/1),
        Total = ask(Client, A, B), ok = lawspec_beam_session_task:join(Task), Total
    end).
add_hired(A, B) ->
    ?H:with_pair(fun(Boss, Manager) -> ?S:with_pair(fun(Server, Client) ->
        Task = ?H:spawn_second(Manager, fun manage/1),
        _ = ?H:first_send_0(Boss, Server),
        Total = ask(Client, A, B), ok = lawspec_beam_session_task:join(Task), Total
    end) end).
