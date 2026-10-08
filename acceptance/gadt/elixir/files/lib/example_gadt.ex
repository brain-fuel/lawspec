# User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
defmodule Example.Gadt do
  alias LawSpec.Data, as: D

  def eval_number(%D.ExprNumber{value: v}), do: v
  def eval_number(%D.ExprPlus{left: l, right: r}), do: eval_number(l) + eval_number(r)
  def eval_truth(%D.ExprTruth{value: b}), do: b
  def eval_truth(%D.ExprSame{left: l, right: r}), do: eval_number(l) == eval_number(r)
  def eval_truth(%D.ExprNegate{operand: x}), do: not eval_truth(x)
  def eval_pair(%D.ExprBoth{first: l, second: r}), do: %D.Pair{first: eval_number(l), second: eval_truth(r)}
  def fold(x), do: %D.ExprNumber{value: eval_number(x)}
  def describe(%D.Shown{lawspec_type_0: witness}), do: witness
end
