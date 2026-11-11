# ref:DEC-tests-cite-requirements ref:DEC-actors-otp-supervision
defmodule Example.Restarts do
  alias LawSpec.Data.{Pair, Tab}
  alias LawSpec.Actors.Example.Restarts.TabActor
  alias LawSpec.Supervisors.Example.Restarts.BarSupervisor

  def open_tab(:ok), do: %Tab{total: 0}
  def add(%Tab{total: total}, amount) do
    %Pair{first: total + amount, second: %Tab{total: total + amount}}
  end
  def total(%Tab{total: total} = state), do: %Pair{first: total, second: state}

  def keeps_total(amount) do
    bar = BarSupervisor.start()
    actor = BarSupervisor.tab(bar)
    try do
      TabActor.add(actor, amount)
      TabActor.crash(actor)
      TabActor.total(actor)
    after
      BarSupervisor.stop(bar)
    end
  end
end
