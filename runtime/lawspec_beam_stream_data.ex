# Native StreamData generation and shrinking for the shared checked Core.
# ref:DEC-native-property-frameworks ref:DEC-shrink-within-domain
defmodule LawSpec.Beam.StreamData do
  @moduledoc false
  alias StreamData, as: SD
  @empty :"$lawspec_empty_domain"

  def generator(type, schema, symbols, bounds, witnesses) do
    :lawspec_beam_generators.generator(__MODULE__, type, schema, symbols, bounds, witnesses)
  end

  def generator(type, schema, symbols, bounds, witnesses, index) do
    :lawspec_beam_generators.generator(__MODULE__, type, schema, symbols, bounds, witnesses, index)
  end

  def exactly(value), do: SD.constant(value)
  def sized(build), do: SD.sized(build)
  def frequency(choices), do: SD.frequency(choices)
  def oneof(choices), do: SD.one_of(choices)
  def list(type), do: SD.list_of(type)
  def vector(count, type), do: SD.list_of(type, length: count)
  def fixed_list(types), do: SD.fixed_list(types)
  def binary(), do: SD.binary()

  def integer(:none, :none), do: SD.integer()
  def integer(lo, :none), do: SD.map(SD.non_negative_integer(), &(&1 + lo))
  def integer(:none, hi), do: SD.map(SD.non_negative_integer(), &(hi - &1))
  def integer(lo, hi), do: SD.integer(lo..hi)

  def bind(type, build) do
    SD.bind(type, fn
      @empty -> exactly(@empty)
      value ->
        case build.(value) do
          %SD{} = generator -> generator
          constant -> exactly(constant)
        end
    end)
  end

  def constrain(type, predicate) do
    filter(type, fn value -> value == @empty or predicate.(value) end)
  end

  def refine_input(type, predicate) do
    bind(type, fn value -> if predicate.(value), do: value, else: @empty end)
  end

  def complete(type), do: filter(type, &(&1 != @empty))
  def forall(type, predicate), do: {type, predicate}

  defp filter(type, predicate) do
    SD.sized(fn _ -> SD.filter(type, predicate, Process.get({__MODULE__, :attempts}, 100)) end)
  end

  # Catch failures inside check_all so StreamData can shrink them with its
  # own tree. Preserve the smallest arguments and the native exception.
  # ref:DEC-never-pass-vacuously ref:DEC-portable-seeded-generation
  def check(label, {type, predicate}, options) do
    seed = case System.get_env("LAWSPEC_SEED") do
      nil -> :erlang.bxor(System.system_time(:nanosecond), System.unique_integer([:positive]))
      text -> String.to_integer(text)
    end
    settings = [
      initial_seed: {:erlang.band(seed, 0xFFFFFFFF), :erlang.band(:erlang.bsr(seed, 32), 0xFFFFFFFF), 1},
      max_runs: Keyword.fetch!(options, :numtests),
      max_shrinking_steps: Keyword.fetch!(options, :max_shrinks)
    ]
    previous = Process.get({__MODULE__, :attempts})
    Process.put({__MODULE__, :attempts}, Keyword.fetch!(options, :constraint_tries))
    try do
      result = :lawspec_beam_generators.with_cache(fn ->
        SD.check_all(type, settings, fn values ->
          try do
            case predicate.(values) do
              true -> {:ok, values}
              false -> {:error, {:counterexample, values}}
              other -> :erlang.error({:lawspec, {:non_boolean_property, other}})
            end
          catch
            kind, reason -> {:error, {:counterexample, values, kind, reason, __STACKTRACE__}}
          end
        end)
      end)
      case result do
        {:ok, _} -> :ok
        {:error, failure} -> :erlang.error({:lawspec, {:property_failed, label, {:seed, seed}, failure}})
      end
    catch
      :error, {:lawspec, {:property_failed, _, _, _}} = failure -> :erlang.error(failure)
      kind, reason ->
        :erlang.raise(:error, {:lawspec, {:property_failed, label, {:seed, seed}, {kind, reason}}}, __STACKTRACE__)
    after
      if previous == nil do
        Process.delete({__MODULE__, :attempts})
      else
        Process.put({__MODULE__, :attempts}, previous)
      end
    end
  end
end
