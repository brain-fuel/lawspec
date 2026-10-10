# ref:REQ-law-primitives ref:REQ-harness-units
defmodule Example.ResourceOwners do
  def open_store(v), do: :beam_owner_support.open(v)
  def close_store(v), do: :beam_owner_support.close(v)
  def empty(v), do: :beam_owner_support.empty(v)
  def touch(v), do: :beam_owner_support.touch(v)
end
