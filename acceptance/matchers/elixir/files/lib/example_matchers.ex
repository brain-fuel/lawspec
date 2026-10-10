# ref:DEC-acceptance-with-mutants
defmodule Example.Matchers do
  def sort_items(items), do: Enum.sort(items)
  def unique_tags(tags), do: Enum.uniq(tags)
  def average(a, b), do: :lawspec_beam_scalar.float_from_native(64, (a + b) / 2)
  def ship(id), do: %LawSpec.Data.OrderShipped{id: id, carrier: "post"}

  def slug(title) do
    Regex.scan(~r/[a-z0-9]+/, String.downcase(title))
    |> Enum.map(&hd/1)
    |> Enum.join("-")
  end
end
