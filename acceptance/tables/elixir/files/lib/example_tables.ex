# ref:DEC-acceptance-with-mutants
defmodule Example.Tables do
  def shipping_cost(kilograms, kilometres), do: kilograms * kilometres + 5 * kilograms
  def label(parcel), do: "parcel #{parcel}"
end
