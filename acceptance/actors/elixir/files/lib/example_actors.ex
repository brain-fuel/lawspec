# ref:DEC-tests-cite-requirements ref:DEC-actors-otp-supervision
defmodule Example.Actors do
  alias LawSpec.Data.{Account, Pair}
  alias LawSpec.Actors.Example.Actors.AccountActor
  alias LawSpec.Supervisors.Example.Actors.BankSupervisor

  def open_account(:ok), do: %Account{balance: 0}
  def deposit(%Account{balance: balance}, amount) do
    %Pair{first: balance + amount, second: %Account{balance: balance + amount}}
  end
  def withdraw_all(%Account{balance: balance}), do: %Pair{first: balance, second: %Account{balance: 0}}
  def balance(%Account{balance: balance} = state), do: %Pair{first: balance, second: state}
  def close(_state), do: %Account{balance: 0}
  def reopen(state), do: state

  def deposit_twice(amount) do
    actor = AccountActor.start()
    try do
      :lawspec_beam_runtime.concurrently([
        fn -> AccountActor.deposit(actor, amount) end,
        fn -> AccountActor.deposit(actor, amount) end
      ])
      AccountActor.balance(actor)
    after
      AccountActor.stop(actor)
    end
  end

  def survives_crash(amount) do
    bank = BankSupervisor.start()
    actor = BankSupervisor.account(bank)
    try do
      AccountActor.deposit(actor, amount)
      AccountActor.crash(actor)
      AccountActor.balance(actor)
    after
      BankSupervisor.stop(bank)
    end
  end

  def native_probe(:ok) do
    :beam_actor_api_probe.with_parent(BankSupervisor.child_spec([]), fn parent ->
      bank = BankSupervisor.from_process(:beam_actor_api_probe.child(parent))
      actor = BankSupervisor.account(bank)
      ^actor = :beam_actor_api_probe.round_trip(actor)
      :ok = AccountActor.monitor(actor, self())
      old = AccountActor.worker_pid(actor)
      5 = AccountActor.deposit(actor, 5)
      :ok = AccountActor.tell_deposit(actor, 3)
      8 = AccountActor.balance(actor)
      :ok = AccountActor.crash(actor)
      receive do
        {:lawspec_actor_event, ^actor, {:crashed, _}} -> :ok
      after
        1000 -> raise "missing crash notification"
      end
      false = old == AccountActor.worker_pid(actor)
      8 = AccountActor.withdraw_all(actor)
      :ok = AccountActor.close(actor)
      :ok = AccountActor.tell_close(actor)
      0 = AccountActor.balance(actor)
      true
    end)
  end
end
