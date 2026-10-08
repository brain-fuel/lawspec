# User-owned LawSpec adapter. Implement these functions.
defmodule Example.Gadt do
  @spec eval_number(LawSpec.Data.expr(integer())) :: integer()

  def eval_number(_argument0) do raise "Not implemented: example.gadt::evalNumber" end

  @spec eval_truth(LawSpec.Data.expr(boolean())) :: boolean()

  def eval_truth(_argument0) do raise "Not implemented: example.gadt::evalTruth" end

  @spec eval_pair(LawSpec.Data.expr(LawSpec.Data.pair(integer(), boolean()))) ::
    LawSpec.Data.pair(integer(), boolean())

  def eval_pair(_argument0) do raise "Not implemented: example.gadt::evalPair" end

  @spec fold(LawSpec.Data.expr(integer())) :: LawSpec.Data.expr(integer())

  def fold(_argument0) do raise "Not implemented: example.gadt::fold" end

  @spec describe(LawSpec.Data.shown()) :: binary()

  def describe(_argument0) do raise "Not implemented: example.gadt::describe" end
end
