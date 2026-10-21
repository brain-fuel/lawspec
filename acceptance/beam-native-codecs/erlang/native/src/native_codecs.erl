-module(native_codecs).
-export([copy_parcel/1, copy_nested/1, copy_chain/1, copy_positive/1,
    to_parcel/2, from_parcel/2, to_chain/2, from_chain/2, to_positive/1, from_positive/1]).
-define(CHAIN_PAYLOAD, record5eebfa15fa6145a8da5c04a1c56125f8f3b2caeb2a02d9cb36e95342d4209998).

copy_parcel(#{private := V}) -> #{private => V}.
copy_nested(#{private := absent}) -> #{private => absent};
copy_nested(#{private := {present, V}}) -> #{private => {present, copy_parcel(V)}}.
copy_chain(#{items := Items, ended := Ended}) -> #{items => Items, ended => Ended}.
copy_positive(#{positive := V}) -> #{positive => V}.

to_parcel({parcel, V}, Convert) -> #{private => Convert(V)}.
from_parcel(#{private := V}, Convert) -> {parcel, Convert(V)}.
to_chain(Value, Convert) -> to_chain(Value, Convert, []).
to_chain(chain_stop, _, Items) -> #{items => lists:reverse(Items), ended => true};
to_chain({chain_more, {?CHAIN_PAYLOAD, V, absent}}, Convert, Items) -> #{items => lists:reverse([Convert(V) | Items]), ended => false};
to_chain({chain_more, {?CHAIN_PAYLOAD, V, {present, Tail}}}, Convert, Items) -> to_chain(Tail, Convert, [Convert(V) | Items]).
from_chain(#{items := Items, ended := Ended}, Convert) ->
    Tail = case Ended of true -> {present, chain_stop}; false -> absent end,
    {present, Result} = lists:foldr(fun(V, Rest) -> {present, {chain_more, {?CHAIN_PAYLOAD, Convert(V), Rest}}} end, Tail, Items),
    Result.
to_positive({positive, V}) -> #{positive => V}.
from_positive(#{positive := V}) -> {positive, V}.
