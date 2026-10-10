%% ref:DEC-acceptance-with-mutants
-module(example_tables).
-export([shipping_cost/2, label/1]).

shipping_cost(Kilograms, Kilometres) -> Kilograms * Kilometres + 5 * Kilograms.
label(Parcel) -> <<"parcel ", (integer_to_binary(Parcel))/binary>>.
