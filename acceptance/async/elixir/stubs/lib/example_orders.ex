# User-owned LawSpec adapter. Implement these functions.
defmodule Example.Orders do
  @spec price(binary()) :: -2147483648..2147483647

  def price(_argument0) do raise "Not implemented: example.orders::price" end

  @spec stock(binary()) :: -2147483648..2147483647

  def stock(_argument0) do raise "Not implemented: example.orders::stock" end

  @spec quote_lawspec(binary()) :: -2147483648..2147483647

  def quote_lawspec(_argument0) do raise "Not implemented: example.orders::quote" end
end
