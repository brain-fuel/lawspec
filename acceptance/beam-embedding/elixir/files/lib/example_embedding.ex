# User-owned LawSpec adapter: an application that makes spec handlers itself.
defmodule Example.Embedding do
  alias LawSpec.Abilities.Example.Embedding.{Balance, Ledger, Tally}
  alias LawSpec.Handlers.ExampleEmbedding, as: Handlers

  @spec embed(integer()) :: integer()
  def embed(n) do
    :lawspec_abilities.with_context(fn context ->
      tally = Handlers.keeping(context)
      :ok = Handlers.keeping_set_state(tally, 10)
      {:error, %LawSpec.Data.RefusalNegative{}} = Tally.try_add(tally, -1)
      {:ok, _} = Tally.try_add(tally, n)
      # The typed state, kept and put back without conversion.
      snapshot = Handlers.keeping_typed_state(tally)
      {:ok, _} = Tally.try_add(tally, 5)
      :ok = Handlers.keeping_set_typed_state(tally, snapshot)
      Handlers.keeping_state(tally)
    end)
  end

  @spec share_book(integer()) :: integer()
  def share_book(n) do
    :lawspec_abilities.with_context(fn context ->
      {ledger, balance} = Handlers.book(context)
      :ok = ledger.record.(n)
      balance.balance.()
    end)
  end

  @spec tally_handler() :: Tally.t()
  def tally_handler(), do: %Tally{add: fn n -> n end}

  @spec ledger_handler() :: Ledger.t()
  def ledger_handler(), do: %Ledger{record: fn _ -> :ok end}

  @spec balance_handler() :: Balance.t()
  def balance_handler(), do: %Balance{balance: fn -> 0 end}
end
