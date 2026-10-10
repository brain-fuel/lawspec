%% PropEr's native bind retains shrinking of the integer number of cents.
-module(payment_generators).
-export([prices/0]).
-include("payments_domain.hrl").

prices() ->
    proper_types:bind(proper_types:integer(100, 200), fun(Cents) ->
        proper_types:exactly(#price{unit = euros,
            major = lawspec_beam_scalar:decimal(Cents, -2)})
    end, false).
