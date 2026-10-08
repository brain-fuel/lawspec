# ref:DEC-acceptance-with-mutants
defmodule Example.Orders do
  def price(sku), do: price_of(sku)
  def stock(sku), do: length(String.codepoints(sku))
  def quote_lawspec(sku), do: price_of(sku)
  defp price_of("free"), do: 0
  defp price_of(sku), do: rem(length(String.codepoints(sku)), 100)
end
