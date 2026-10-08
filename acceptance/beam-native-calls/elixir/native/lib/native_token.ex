defmodule Native.Token do
  def new() do
    reference = make_ref()
    Process.put(reference, 0)
    reference
  end
  def touch(reference) do
    Process.put(reference, 1)
    :deliberately_non_unit
  end
  def value(reference, n), do: n + Process.get(reference)
end
