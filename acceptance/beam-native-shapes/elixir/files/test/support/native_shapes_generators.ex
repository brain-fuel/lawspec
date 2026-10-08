defmodule Native.ShapesGenerators do
  def boxes(child), do: StreamData.map(child, &%Native.Shapes.Wrapped{stored: &1})
  def small_int(), do: StreamData.integer(6..127)
  def stamps(), do: raise("finite type must not call factory")
end
