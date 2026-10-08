-module(example_builtins).
-export([elapsed/2, token/2, listening/2, charge/2]).

elapsed(#{now := Now}, Count) ->
    {instant, Start} = Now(),
    lists:foreach(fun(_) -> Now() end, lists:seq(1, Count)),
    {instant, Finish} = Now(),
    {duration, Finish - Start}.

token(#{secure_bytes := SecureBytes}, Count) -> SecureBytes(Count).

listening(#{free_port := FreePort}, _Count) ->
    {ok, Socket} = gen_tcp:listen(FreePort(), [{ip, {127, 0, 0, 1}}, {active, false}]),
    gen_tcp:close(Socket),
    true.

charge(#{log_message := LogMessage}, Cents) ->
    case Cents rem 2 of
        0 -> LogMessage(log_level_info, <<"charged">>), true;
        _ -> false
    end.
