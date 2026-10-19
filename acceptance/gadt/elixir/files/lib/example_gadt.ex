# User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
defmodule Example.Gadt do
  alias LawSpec.Data, as: D

  def eval_number(%D.ExprNumber{value: v}), do: v
  def eval_number(%D.ExprPlus{value: %D.Record772b3aa87ecd053fcced573681dbd8344f63903af98f493d5b458b00157f001e{left: l, right: r}}), do: eval_number(l) + eval_number(r)
  def eval_truth(%D.ExprTruth{value: b}), do: b
  def eval_truth(%D.ExprSame{value: %D.Record772b3aa87ecd053fcced573681dbd8344f63903af98f493d5b458b00157f001e{left: l, right: r}}), do: eval_number(l) == eval_number(r)
  def eval_truth(%D.ExprNegate{value: x}), do: not eval_truth(x)
  def eval_pair(%D.ExprBoth{value: %D.Recorddf69a8df6c38a0adbe741f620a312261d0d3b0973eba2bc27135c83989a8365e{first: l, second: r}}), do: %D.Pair{first: eval_number(l), second: eval_truth(r)}
  def fold(x), do: %D.ExprNumber{value: eval_number(x)}
  def describe(%D.Shown{lawspec_type_0: witness}), do: witness
end
