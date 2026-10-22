-module(native_shapes).
-export([copy_box/1, copy_chain/1, copy_tree/1, copy_nested/1, copy_stamp/1]).
-include("native_shapes.hrl").

copy_box(#wrapped{audit = retained, stored = V}) -> #wrapped{stored = V}.
copy_chain('end') -> 'end';
copy_chain({next, V, Tail}) -> {next, V, chain_tail(Tail)}.
chain_tail(absent) -> absent;
chain_tail({present, Tail}) -> {present, copy_chain(Tail)}.
copy_tree({item, V}) -> {item, V};
copy_tree({group, Trees}) -> {group, [copy_tree(T) || T <- Trees]}.
copy_nested(#wrapped{stored = absent}) -> #wrapped{stored = absent};
copy_nested(#wrapped{stored = {present, Box}}) -> #wrapped{stored = {present, copy_box(Box)}}.
copy_stamp(#seal{}) -> #seal{}.
