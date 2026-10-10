%% ref:DEC-acceptance-with-mutants
-module(shop_domain).
-export([convert/2]).
convert(Currency, {money, _, Cents}) -> {money, Currency, Cents}.
