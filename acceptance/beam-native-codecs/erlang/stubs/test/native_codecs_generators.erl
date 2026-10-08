%% User-owned LawSpec adapter. Implement these functions.
-module(native_codecs_generators).
-export([parcels/1, positives/0]).

-spec parcels(proper_types:raw_type()) -> proper_types:raw_type().

parcels(_Child0) ->
    erlang:error({not_implemented, <<"Implement generator for native.codecs::type::Parcel"/utf8>>}).

-spec positives() -> proper_types:raw_type().

positives() ->
    erlang:error(
        {not_implemented, <<"Implement generator for native.codecs::type::Positive"/utf8>>}
    ).
