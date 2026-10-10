# ref:DEC-acceptance-with-mutants
defmodule Example.ParsePort do
  def valid_port(value), do: value >= 1 and value <= 65535
  def render(value) do
    true = valid_port(value)
    Integer.to_string(value)
  end
  def parse(value), do: String.to_integer(value)
end
