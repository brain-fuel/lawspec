%% User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
-module(example_indexed).
-export([replicate/2, append/2, zip/2, flatten/1]).

replicate(0, _) -> vec_v_nil;
replicate(N, X) -> {vec_v_cons, {v_cons_details, X, replicate(N - 1, X)}}.

append(vec_v_nil, Ys) -> Ys;
append({vec_v_cons, {v_cons_details, H, T}}, Ys) -> {vec_v_cons, {v_cons_details, H, append(T, Ys)}}.

zip(vec_v_nil, vec_v_nil) -> vec_v_nil;
zip({vec_v_cons, {v_cons_details, _, T}}, {vec_v_cons, {v_cons_details, H, U}}) -> {vec_v_cons, {v_cons_details, H, zip(T, U)}}.

flatten(tree_tip) -> vec_v_nil;
flatten({tree_bin, {bin_details, L, R, V}}) -> append(flatten(L), {vec_v_cons, {v_cons_details, V, flatten(R)}}).
