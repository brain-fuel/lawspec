# ref:REQ-law-primitives ref:REQ-harness-units
defmodule Example.SharedPeer do
  defdelegate open_pool(unit), to: :beam_shared_resource_support
  defdelegate reset_pool(pool), to: :beam_shared_resource_support
  defdelegate close_pool(pool), to: :beam_shared_resource_support
  defdelegate use_pool(pool), to: :beam_shared_resource_support
end
