# User-owned LawSpec adapter. Implement these functions.
defmodule Native.ShapesGenerators do
  @spec boxes(StreamData.t(a0)) :: StreamData.t(Native.Shapes.Wrapped.t(a0)) when a0: term()

  def boxes(_child0) do raise("Implement generator for native.shapes::type::Box") end

  @spec small_int() :: StreamData.t(-128..127)

  def small_int() do raise("Implement generator for Int8") end

  @spec stamps() :: StreamData.t(Native.Shapes.Seal.t())

  def stamps() do raise("Implement generator for native.shapes::type::Stamp") end
end
