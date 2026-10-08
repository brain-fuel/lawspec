# User-owned LawSpec adapter. Implement these functions.
defmodule Example.AsyncWorkflows do
  @spec first(LawSpec.Abilities.Example.AsyncWorkflows.Coordination.t(), -128..127) ::
    {:left, binary()} | {:right, -128..127}

  def first(_handler0, _argument0) do raise "Not implemented: example.asyncWorkflows::first" end

  @spec second(LawSpec.Abilities.Example.AsyncWorkflows.Coordination.t(), -128..127) ::
    {:left, binary()} | {:right, -128..127}

  def second(_handler0, _argument0) do raise "Not implemented: example.asyncWorkflows::second" end

  @spec public_probe(:ok) :: boolean()

  def public_probe(_argument0) do raise "Not implemented: example.asyncWorkflows::publicProbe" end

  @spec coordination_handler() :: LawSpec.Abilities.Example.AsyncWorkflows.Coordination.t()

  def coordination_handler() do
    %LawSpec.Abilities.Example.AsyncWorkflows.Coordination{meet: fn _argument0 -> raise "Not implemented: example.asyncWorkflows::ability::Coordination.meet" end, finish: fn _argument0 -> raise "Not implemented: example.asyncWorkflows::ability::Coordination.finish" end}
  end
end
