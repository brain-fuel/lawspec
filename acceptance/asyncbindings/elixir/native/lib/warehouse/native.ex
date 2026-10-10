# ref:DEC-acceptance-with-mutants ref:DEC-async-native-tasks
defmodule Warehouse.Native do
  def price_of(sku) do
    :erlang.yield()
    quote_of(sku)
  end
  def quote_of("free"), do: 0
  def quote_of(sku), do: rem(length(String.to_charlist(sku)), 100)
  def new(), do: :atomics.new(1, [])
  def restock(shelf, amount) do
    :erlang.yield()
    :atomics.add(shelf, 1, amount)
    :ok
  end
  def count(shelf) do
    :erlang.yield()
    :atomics.get(shelf, 1)
  end
end
