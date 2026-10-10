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
  def clear(_), do: %Counter{value: 0}
  def echo(state, value), do: %Pair{first: value, second: state}
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

  def remote_probe(:ok) do
    :beam_remote_probe.with_nodes(fn a, b ->
      RootSupervisor.with_supervisor(%Factor{adjust: fn n -> 3 * n end}, restore_handler(), fn root ->
        bank = RootSupervisor.bank(root)
        actor = BankSupervisor.counter(bank)
        address = CounterActor.serve(actor, b, "counter")
        remote = CounterActor.Remote.connect(a, address)
        21 = CounterActor.Remote.add(remote, 7)
        21 = CounterActor.Remote.total(remote)
        CounterActor.crash(actor)
        31 = CounterActor.Remote.total(remote)
        BankSupervisor.stop(bank)
        41 = CounterActor.Remote.total(remote)
        fast = CounterActor.Remote.connect_with_timeout(a, address, 1000)
        {:just, [0, -7]} = CounterActor.Remote.echo(fast, {:just, [0, -7]})
        :ok = CounterActor.Remote.clear(fast)
        0 = CounterActor.Remote.total(remote)
        :lawspec_beam_node.stop(b)
        0 = CounterActor.total(actor)
        true
      end)
    end)
  end
end
