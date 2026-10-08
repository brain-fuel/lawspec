# ref:DEC-tests-cite-requirements ref:DEC-actors-otp-supervision
defmodule Example.ActorAbilities do
  alias LawSpec.Data.{Counter, Pair}
  alias LawSpec.Abilities.Example.ActorAbilities.{Factor, Restore}
  alias LawSpec.Actors.Example.ActorAbilities.CounterActor
  alias LawSpec.Supervisors.Example.ActorAbilities.{RootSupervisor, BankSupervisor}

  def factor_handler(), do: %Factor{adjust: fn n -> 2 * n end}
  def restore_handler(), do: %Restore{restore: fn n -> n + 10 end}
  def open_counter(:ok), do: %Counter{value: 0}
  def add(factor, %Counter{value: n}, amount) do
    next = n + factor.adjust.(amount)
    %Pair{first: next, second: %Counter{value: next}}
  end
  def total(%Counter{value: n} = state), do: %Pair{first: n, second: state}
  def reopen(restore, %Counter{value: n}), do: %Counter{value: restore.restore.(n)}

  def native_probe(:ok) do
    RootSupervisor.with_supervisor(factor_handler(), restore_handler(), fn root ->
      bank = RootSupervisor.bank(root)
      actor = BankSupervisor.counter(bank)
      14 = CounterActor.add(actor, 7)
      CounterActor.crash(actor)
      24 = CounterActor.total(actor)
      CounterActor.tell_add(actor, 3)
      30 = CounterActor.total(actor)
      BankSupervisor.stop(bank)
      40 = CounterActor.total(actor)
      true
    end)
  end
end
