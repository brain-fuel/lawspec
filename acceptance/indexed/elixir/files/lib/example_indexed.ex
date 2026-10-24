# User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
defmodule Example.Indexed do
  alias LawSpec.Data, as: D

  def replicate(0, _), do: %D.VecVNil{}
  def replicate(n, x), do: %D.VecVCons{value: %D.VConsDetails{head: x, tail: replicate(n - 1, x)}}
  def append(%D.VecVNil{}, ys), do: ys
  def append(%D.VecVCons{value: %D.VConsDetails{head: h, tail: t}}, ys), do: %D.VecVCons{value: %D.VConsDetails{head: h, tail: append(t, ys)}}
  def zip(%D.VecVNil{}, %D.VecVNil{}), do: %D.VecVNil{}
  def zip(%D.VecVCons{value: %D.VConsDetails{tail: t}}, %D.VecVCons{value: %D.VConsDetails{head: h, tail: u}}), do: %D.VecVCons{value: %D.VConsDetails{head: h, tail: zip(t, u)}}
  def flatten(%D.TreeTip{}), do: %D.VecVNil{}
  def flatten(%D.TreeBin{value: %D.BinDetails{left: l, value: v, right: r}}), do: append(flatten(l), %D.VecVCons{value: %D.VConsDetails{head: v, tail: flatten(r)}})
end
