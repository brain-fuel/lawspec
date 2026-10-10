# ref:DEC-acceptance-with-mutants
defmodule Example.Alternatives do
  def render(value), do: Integer.to_string(value)
  def reference_render(value), do: to_string(value)
  def clamp(value), do: max(0, value)
  def reference_clamp(value), do: if(value < 0, do: 0, else: value)
end
