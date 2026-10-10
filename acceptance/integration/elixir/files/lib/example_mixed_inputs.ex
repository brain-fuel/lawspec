# ref:DEC-acceptance-with-mutants
defmodule Example.Mixed.Inputs do
  def normalize(value), do: String.replace(value, " ", "-")
  def identity(value), do: value
end
