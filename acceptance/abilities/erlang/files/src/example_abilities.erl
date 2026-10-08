%% User-owned native functions and production ability interface.
-module(example_abilities).
-export([charge/2, gateway_handler/0]).

charge(Gateway, Cents) ->
    case (maps:get(authorize, Gateway))(Cents) of
        {payment_approved, Approved} ->
            {receipt, Paid} = (maps:get(capture, Gateway))(Approved),
            Paid =:= Cents;
        payment_declined -> false
    end.

gateway_handler() ->
    #{authorize => fun(Cents) ->
          case Cents < 0 of true -> payment_declined; false -> {payment_approved, Cents} end
      end,
      capture => fun(Cents) -> {receipt, Cents} end,
      fee => fun() -> 25 end}.
