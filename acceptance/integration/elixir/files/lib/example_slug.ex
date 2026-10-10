# ref:DEC-acceptance-with-mutants
defmodule Example.Slug do
  def normalize(value), do: String.replace(value, " ", "-")
  def reference_normalize(value), do: value |> String.split(" ") |> Enum.join("-")
end
