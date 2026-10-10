# ref:DEC-acceptance-with-mutants
defmodule Example.Algebra do
  def add(a, b), do: a + b
  def multiply(a, b), do: a * b
  def negate_value(a), do: -a
  def maximum_value(a, b), do: max(a, b)
  def subtract_value(a, b), do: a - b
  def divide_left(a, b), do: a - b
  def divide_right(a, b), do: a + b
end
