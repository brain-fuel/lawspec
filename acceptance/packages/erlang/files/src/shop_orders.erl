%% ref:DEC-acceptance-with-mutants
-module(shop_orders).
-export([settlement/1, line_total/1, cheaper/2, round_down/1, classify/1]).
settlement(shop_orders_type_currency_usd) -> shop_domain_type_currency_usd;
settlement(shop_orders_type_currency_gbp) -> shop_domain_type_currency_eur.
line_total({line, {money, Currency, Cents}, {quantity, Count}}) ->
    {money, Currency, min(Cents * Count, 100000000)}.
cheaper(A, B) -> min(A, B).
round_down(Value) -> Value - Value rem 100.
classify(Value) when Value =< 0 -> shop_tax_v2x0x0_rates_type_band_zero;
classify(Value) when Value < 10000 -> shop_tax_v2x0x0_rates_type_band_low;
classify(_) -> shop_tax_v2x0x0_rates_type_band_high.
