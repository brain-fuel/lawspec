# User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
defmodule Example.Indexed do
  alias LawSpec.Data, as: D

  def replicate(0, _), do: %D.VecVNil{}
  def replicate(n, x), do: %D.VecVCons{head: x, tail: replicate(n - 1, x)}
  def append(%D.VecVNil{}, ys), do: ys
  def append(%D.VecVCons{head: h, tail: t}, ys), do: %D.VecVCons{head: h, tail: append(t, ys)}
  def zip(%D.VecVNil{}, %D.VecVNil{}), do: %D.VecVNil{}
  def zip(%D.VecVCons{tail: t}, %D.VecVCons{head: h, tail: u}), do: %D.VecVCons{head: h, tail: zip(t, u)}
  def flatten(%D.TreeTip{}), do: %D.VecVNil{}
  def flatten(%D.TreeBin{left: l, value: v, right: r}), do: append(flatten(l), %D.VecVCons{head: v, tail: flatten(r)})
end
