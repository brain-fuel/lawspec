defmodule Native.Token do
  def new() do
    :atomics.new(1, [])
  end
  def touch(reference) do
    :atomics.put(reference, 1, 1)
    :deliberately_non_unit
  end
  def value(reference, n), do: n + :atomics.get(reference, 1)
end
