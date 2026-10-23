# User-owned LawSpec adapter. Implement these functions.
defmodule Example.Gadt do
  @spec eval_number(LawSpec.Data.expr(integer())) :: integer()

  def eval_number(_expr_integer) do
    raise "Not implemented: example.gadt::evalNumber"
  end

  @spec eval_truth(LawSpec.Data.expr(boolean())) :: boolean()

  def eval_truth(_expr_bool) do
    raise "Not implemented: example.gadt::evalTruth"
  end

  @spec eval_pair(LawSpec.Data.expr(LawSpec.Data.pair(integer(), boolean()))) ::
          LawSpec.Data.pair(integer(), boolean())

  def eval_pair(_expr_pair_integer_bool) do
    raise "Not implemented: example.gadt::evalPair"
  end

  @spec fold(LawSpec.Data.expr(integer())) :: LawSpec.Data.expr(integer())

  def fold(_expr_integer) do
    raise "Not implemented: example.gadt::fold"
  end

  @spec describe(LawSpec.Data.shown()) :: binary()

  def describe(_shown) do
    raise "Not implemented: example.gadt::describe"
  end
end
