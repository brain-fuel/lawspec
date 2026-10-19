%% User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
-module(example_indexed).
-export([replicate/2, append/2, zip/2, flatten/1]).

replicate(0, _) -> vec_v_nil;
replicate(N, X) -> {vec_v_cons, {record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec, X, replicate(N - 1, X)}}.

append(vec_v_nil, Ys) -> Ys;
append({vec_v_cons, {record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec, H, T}}, Ys) -> {vec_v_cons, {record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec, H, append(T, Ys)}}.

zip(vec_v_nil, vec_v_nil) -> vec_v_nil;
zip({vec_v_cons, {record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec, _, T}}, {vec_v_cons, {record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec, H, U}}) -> {vec_v_cons, {record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec, H, zip(T, U)}}.

flatten(tree_tip) -> vec_v_nil;
flatten({tree_bin, {recorde00f7d8e028cf6be6e08b4ed1f9853199bee01cf39e5a2faa3e38b8ad29bf271, L, R, V}}) -> append(flatten(L), {vec_v_cons, {record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec, V, flatten(R)}}).
