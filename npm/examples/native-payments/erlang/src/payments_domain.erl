%% Application-owned payment types; no generated domain declarations.
-module(payments_domain).
-export([apply_fee/1, restore/1, store/1]).
-export_type([currency_code/0, price/0, payment_status/0]).
-include("payments_domain.hrl").

-type currency_code() :: dollars | euros | pounds.
-type price() :: #price{unit :: currency_code(), major :: lawspec_beam_scalar:decimal()}.
-type payment_status() :: {settled, price()} | {rejected, binary()}.

-spec apply_fee(price()) -> price().
apply_fee(#price{major = Amount} = Price) ->
    Fee = lawspec_beam_scalar:decimal(2, -1),
    Price#price{major = lawspec_beam_scalar:binary(
        <<"+">>, Amount, Fee, <<"Decimal">>, <<"Decimal">>)}.

-spec restore(payment_status()) -> payment_status().
restore(Payment) -> Payment.

-spec store([nothing | {just, payment_status()}]) -> [nothing | {just, payment_status()}].
store(Payments) -> Payments.
