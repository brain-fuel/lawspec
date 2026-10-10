# ref:REQ-law-primitives ref:REQ-harness-units
defmodule Example.SharedResources do
  alias LawSpec.Abilities.Example.SharedResources, as: Abilities
  defdelegate open_store(tick), to: :beam_shared_resource_support
  defdelegate reset_store(store, tick), to: :beam_shared_resource_support
  defdelegate close_store(store, tick), to: :beam_shared_resource_support
  defdelegate use_store(store, value), to: :beam_shared_resource_support
  defdelegate store_value(store), to: :beam_shared_resource_support
  defdelegate open_group(unit), to: :beam_shared_resource_support
  defdelegate reset_group(store), to: :beam_shared_resource_support
  defdelegate close_group(store), to: :beam_shared_resource_support
  defdelegate use_group(store), to: :beam_shared_resource_support
  defdelegate open_pool(unit), to: :beam_shared_resource_support
  defdelegate reset_pool(pool), to: :beam_shared_resource_support
  defdelegate close_pool(pool), to: :beam_shared_resource_support
  defdelegate use_pool(pool), to: :beam_shared_resource_support

  def audit_handler() do
    count = :lawspec_beam_effects.native_cell(0)
    %Abilities.Audit{tick: fn _ ->
      :lawspec_beam_effects.native_write(count, :lawspec_beam_effects.native_read(count) + 1)
    end}
  end
end
