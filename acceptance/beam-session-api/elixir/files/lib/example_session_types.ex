# ref:DEC-tests-cite-requirements ref:DEC-sessions-by-construction
defmodule Example.SessionTypes do
  alias LawSpec.Sessions.Example.SessionTypes.{Exchange, Symbols, Empty}

  def native_probe(:ok) do
    Exchange.with_pair(fn first, second ->
      task = Exchange.spawn_second(second, fn channel_end ->
        {{:just, [1, 2, 3]}, next} = Exchange.second_receive_0(channel_end)
        Exchange.second_send_1(next, :ok)
        :ok
      end)
      next = Exchange.first_send_0(first, {:just, [1, 2, 3]})
      {:ok, _} = Exchange.first_receive_1(next)
      :ok = LawSpec.Sessions.join(task)
    end)
    Symbols.with_pair(fn first, second ->
      identity = :lawspec_beam_scalar.new_symbol("session")
      Symbols.first_send_0(first, identity)
      {^identity, _} = Symbols.second_receive_0(second)
    end)
    Empty.with_pair(fn _, _ -> true end)
  end
end
