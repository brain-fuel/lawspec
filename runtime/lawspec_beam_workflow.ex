# ref:DEC-domain-modeling-primitives ref:DEC-idiomatic-generated-types
defmodule LawSpec.Workflow do
  @moduledoc """
  Scoped policy state for generated workflows. Calls and their async workers
  share this runtime until the callback returns. Time is in microseconds.
  """
  @opaque runtime :: map()
  @type event :: {String.t(), String.t(), integer(), boolean()}

  @spec with_virtual(integer(), (runtime() -> result)) :: result when result: var
  def with_virtual(seed \\ 0, body), do: :lawspec_beam_workflow.with_virtual(seed, body)

  @spec with_real(integer(), (runtime() -> result)) :: result when result: var
  def with_real(seed \\ 0, body), do: :lawspec_beam_workflow.with_real(seed, body)

  @spec with_clock((-> integer()), (integer() -> term()), boolean(), integer(), (runtime() -> result)) :: result when result: var
  def with_clock(now, sleep, virtual, seed \\ 0, body),
    do: :lawspec_beam_workflow.with_clock_callbacks(now, sleep, virtual, seed, body)

  @spec now(runtime()) :: integer()
  def now(runtime), do: :lawspec_beam_workflow.now(runtime)

  @spec sleep(runtime(), integer()) :: :ok
  def sleep(runtime, micros), do: :lawspec_beam_workflow.sleep(runtime, micros)

  @doc "Sets the time of a runtime created with with_virtual."
  @spec set_time(runtime(), integer()) :: :ok
  def set_time(runtime, micros), do: :lawspec_beam_workflow.set_time(runtime, micros)

  @spec trace(runtime()) :: [event()]
  def trace(runtime), do: :lawspec_beam_workflow.trace(runtime)
end
