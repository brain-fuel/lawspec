# User-owned LawSpec adapter. Implement these functions.
defmodule Example.Orders do
  @spec price(binary()) :: -2_147_483_648..2_147_483_647

  def price(_sku) do
    raise "Not implemented: example.orders::price"
  end

  @spec stock(binary()) :: -2_147_483_648..2_147_483_647

  def stock(_text_1) do
    raise "Not implemented: example.orders::stock"
  end

  @spec quote_lawspec(binary()) :: -2_147_483_648..2_147_483_647

  def quote_lawspec(_text_1) do
    raise "Not implemented: example.orders::quote"
  end
end
