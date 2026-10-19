# User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
defmodule Example.Indexed do
  alias LawSpec.Data, as: D

  def replicate(0, _), do: %D.VecVNil{}
  def replicate(n, x), do: %D.VecVCons{value: %D.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec{head: x, tail: replicate(n - 1, x)}}
  def append(%D.VecVNil{}, ys), do: ys
  def append(%D.VecVCons{value: %D.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec{head: h, tail: t}}, ys), do: %D.VecVCons{value: %D.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec{head: h, tail: append(t, ys)}}
  def zip(%D.VecVNil{}, %D.VecVNil{}), do: %D.VecVNil{}
  def zip(%D.VecVCons{value: %D.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec{tail: t}}, %D.VecVCons{value: %D.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec{head: h, tail: u}}), do: %D.VecVCons{value: %D.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec{head: h, tail: zip(t, u)}}
  def flatten(%D.TreeTip{}), do: %D.VecVNil{}
  def flatten(%D.TreeBin{value: %D.Recorde00f7d8e028cf6be6e08b4ed1f9853199bee01cf39e5a2faa3e38b8ad29bf271{left: l, value: v, right: r}}), do: append(flatten(l), %D.VecVCons{value: %D.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec{head: v, tail: flatten(r)}})
end
