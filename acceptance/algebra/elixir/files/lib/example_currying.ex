# ref:DEC-acceptance-with-mutants
defmodule Example.Currying do
  def sum_four(a, b, c, d), do: a + b + c + d
  def format(prefix, enabled, port, suffix) do
    prefix <> if(enabled, do: Integer.to_string(port), else: "") <> suffix
  end
  def reference_format(prefix, enabled, port, suffix) do
    Enum.join([prefix, if(enabled, do: Integer.to_string(port), else: ""), suffix])
  end
  def trim(text), do: String.trim(text)
end
