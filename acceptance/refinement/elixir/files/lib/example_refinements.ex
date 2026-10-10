# ref:DEC-acceptance-with-mutants
defmodule Example.Refinements do
  def add(a, b), do: a + b
  def successor(value), do: value + 1
  def count(text), do: length(String.to_charlist(text))
  def preserve(value), do: value
  def positive(value), do: value
  def abstract_echo(value), do: value
end
