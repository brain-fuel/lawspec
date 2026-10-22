defmodule Native.Shapes.Wrapped do
  defstruct [:stored, audit: :retained]
  @type t(a) :: %__MODULE__{stored: a, audit: atom()}
end
defmodule Native.Shapes.End do
  defstruct []
end
defmodule Native.Shapes.Next do
  defstruct [:remainder, :item]
end
defmodule Native.Shapes.Item do
  defstruct [:datum]
end
defmodule Native.Shapes.Group do
  defstruct [:trees]
end
defmodule Native.Shapes.Seal do
  defstruct []
  @type t :: %__MODULE__{}
end
defmodule Native.Shapes do
  alias Native.Shapes, as: N
  def copy_box(%N.Wrapped{stored: value, audit: :retained}), do: %N.Wrapped{stored: value}
  def copy_chain(%N.End{}), do: %N.End{}
  def copy_chain(%N.Next{item: value, remainder: tail}), do: %N.Next{item: value, remainder: chain_tail(tail)}
  defp chain_tail(:absent), do: :absent
  defp chain_tail({:present, tail}), do: {:present, copy_chain(tail)}
  def copy_tree(%N.Item{datum: value}), do: %N.Item{datum: value}
  def copy_tree(%N.Group{trees: values}), do: %N.Group{trees: Enum.map(values, &copy_tree/1)}
  def copy_nested(%N.Wrapped{stored: :absent}), do: %N.Wrapped{stored: :absent}
  def copy_nested(%N.Wrapped{stored: {:present, box}}), do: %N.Wrapped{stored: {:present, copy_box(box)}}
  def copy_stamp(%N.Seal{}), do: %N.Seal{}
end
