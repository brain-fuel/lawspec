# ref:DEC-acceptance-with-mutants
defmodule Example.Matchers do
  def sort_items(items), do: Enum.sort(items)
  def unique_tags(tags), do: Enum.uniq(tags)
  def average(a, b), do: :lawspec_beam_scalar.float_from_native(64, (a + b) / 2)
  def ship(id), do: %LawSpec.Data.OrderShipped{value: %LawSpec.Data.Recordaaeb2c3925832586ac7d5e3c9a9cd234d3a26f7d9d0e264664a4ae58c6f71911{id: id, carrier: "post"}}

  def slug(title) do
    Regex.scan(~r/[a-z0-9]+/, String.downcase(title))
    |> Enum.map(&hd/1)
    |> Enum.join("-")
  end
end
