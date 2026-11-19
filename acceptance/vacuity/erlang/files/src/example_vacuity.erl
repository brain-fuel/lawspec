%% User-owned LawSpec adapter.
-module(example_vacuity).

-export([shout/1, abbreviate/1, accepts/1, describe/1, keep/1]).

-spec shout(binary()) -> binary().
shout(Name) -> string:uppercase(Name).

-spec abbreviate(lawspec_data:stage()) -> binary().
abbreviate({stage, Token, _Meaning}) -> Token.

%% Accepts only codes such as OFFER-2026-AB: no random record has one.
-spec accepts(lawspec_data:proposal()) -> boolean().
accepts({proposal, Code, Amount}) ->
    re:run(Code, <<"^OFFER-[0-9]{4}-[A-Z]{2}$">>, [unicode]) =/= nomatch andalso Amount > 0.

-spec describe(lawspec_data:proposal()) -> binary().
describe({proposal, Code, _Amount}) -> Code.

-spec keep(binary()) -> binary().
keep(Key) -> Key.
