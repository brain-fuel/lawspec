# ref:DEC-acceptance-with-mutants
defmodule Shop.Domain do
  alias LawSpec.Data, as: D
  def convert(currency, %D.Money{cents: cents}), do: %D.Money{currency: currency, cents: cents}
end
