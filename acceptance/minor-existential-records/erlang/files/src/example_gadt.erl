-module(example_gadt).
-export([describe/1]).
describe({shown, _, Witness}) -> Witness.
