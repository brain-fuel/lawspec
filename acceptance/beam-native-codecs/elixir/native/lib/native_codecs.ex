defmodule Native.Codecs.Parcel do
  @type t(a) :: %{private: a}
end
defmodule Native.Codecs.Positive do
  @type t :: %{positive: pos_integer()}
end
defmodule Native.Codecs do
  alias LawSpec.Data, as: D
  alias D.Record5eebfa15fa6145a8da5c04a1c56125f8f3b2caeb2a02d9cb36e95342d4209998, as: ChainPayload
  def copy_parcel(%{private: value}), do: %{private: value}
  def copy_nested(%{private: :nothing}), do: %{private: :nothing}
  def copy_nested(%{private: {:just, value}}), do: %{private: {:just, copy_parcel(value)}}
  def copy_chain(%{items: items, ended: ended}), do: %{items: items, ended: ended}
  def copy_positive(%{positive: value}), do: %{positive: value}
  def to_parcel(%D.Parcel{item: value}, convert), do: %{private: convert.(value)}
  def from_parcel(%{private: value}, convert), do: %D.Parcel{item: convert.(value)}
  def to_chain(value, convert), do: to_chain(value, convert, [])
  defp to_chain(%D.ChainStop{}, _, items), do: %{items: Enum.reverse(items), ended: true}
  defp to_chain(%D.ChainMore{value: %ChainPayload{item: value, tail: :nothing}}, convert, items), do: %{items: Enum.reverse([convert.(value) | items]), ended: false}
  defp to_chain(%D.ChainMore{value: %ChainPayload{item: value, tail: {:just, tail}}}, convert, items), do: to_chain(tail, convert, [convert.(value) | items])
  def from_chain(%{items: items, ended: ended}, convert) do
    tail = if ended, do: {:just, %D.ChainStop{}}, else: :nothing
    {:just, value} = Enum.reduce(Enum.reverse(items), tail, fn item, rest -> {:just, %D.ChainMore{value: %ChainPayload{item: convert.(item), tail: rest}}} end)
    value
  end
  def to_positive(%D.Positive{value: value}), do: %{positive: value}
  def from_positive(%{positive: value}), do: %D.Positive{value: value}
end
