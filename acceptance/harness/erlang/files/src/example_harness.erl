%% ref:REQ-harness-units ref:DEC-tests-cite-requirements
-module(example_harness).
-export([discount/1, round_cents/1, book/2, ledger_handler/0]).
discount({order, Items, Total}) when Items > 10 -> Total div 10;
discount({order, _, _}) -> 0.
round_cents(Cents) -> ((Cents + 4) div 10) * 10.
book(Ledger, Cents) -> (maps:get(accept, Ledger))(Cents).
ledger_handler() -> #{accept => fun(Cents) -> Cents > 0 end}.
