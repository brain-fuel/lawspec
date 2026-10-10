# ref:DEC-acceptance-with-mutants
defmodule Example.CanonicalUrl do
  def canonicalize(value), do: String.trim_trailing(value, "/")
end
