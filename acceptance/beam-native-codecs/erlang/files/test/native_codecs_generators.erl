-module(native_codecs_generators).
-export([parcels/1, positives/0]).

parcels(Child) -> proper_types:bind(Child, fun(V) -> proper_types:exactly(#{private => V}) end, false).
positives() -> proper_types:bind(proper_types:integer(1, 127), fun(V) -> proper_types:exactly(#{positive => V}) end, false).
