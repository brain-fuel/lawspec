# User-owned LawSpec adapter: native handlers of Logs, Reader and Writer that
# share the case's Store, an ETS table of each log's records.
defmodule Example.Composition do
  alias LawSpec.Abilities.Example.Composition, as: Abilities

  @spec open_store(:ok) :: LawSpec.Data.store()
  def open_store(:ok), do: :ets.new(:composition_store, [:set, :public])

  @spec close_store(LawSpec.Data.store()) :: :ok
  def close_store(store) do
    :ets.delete(store)
    :ok
  end

  @spec logs_handler(LawSpec.Data.store()) :: Abilities.Logs.t()
  def logs_handler(store) do
    %Abilities.Logs{
      create: fn log ->
        :ets.insert(store, {log, []})
        :ok
      end,
      append: fn log, record ->
        case :ets.lookup(store, log) do
          [] -> :lawspec_beam_effects.fail(%LawSpec.Data.ProblemUnknownLog{})
          [{_, _}] when record == "" -> :lawspec_beam_effects.fail(%LawSpec.Data.ProblemEmptyRecord{})
          [{_, records}] ->
            :ets.insert(store, {log, records ++ [record]})
            length(records)
        end
      end
    }
  end

  @spec reader_handler(LawSpec.Data.store()) :: Abilities.Reader.t()
  def reader_handler(store) do
    %Abilities.Reader{
      size: fn log ->
        case :ets.lookup(store, log) do
          [] -> :absent
          [{_, records}] -> {:present, length(records)}
        end
      end
    }
  end

  @spec writer_handler(LawSpec.Data.store()) :: Abilities.Writer.t()
  def writer_handler(store) do
    last = :lawspec_beam_effects.native_cell(:absent)

    %Abilities.Writer{
      write: fn log, record ->
        case :ets.lookup(store, log) do
          [{_, records}] when record != "" ->
            :ets.insert(store, {log, records ++ [record]})
            :lawspec_beam_effects.native_write(last, {:present, length(records)})
            true

          _ ->
            false
        end
      end,
      last_offset: fn -> :lawspec_beam_effects.native_read(last) end
    }
  end
end
