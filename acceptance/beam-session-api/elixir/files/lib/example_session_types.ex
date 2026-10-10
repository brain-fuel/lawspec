# ref:DEC-tests-cite-requirements ref:DEC-sessions-by-construction
defmodule Example.SessionTypes do
  alias LawSpec.Sessions.Example.SessionTypes.{Exchange, Symbols, Empty, Answer, Passing}

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

  def network_probe(:ok) do
    :beam_session_probe.with_nodes(fn a, b, c, d ->
      first = Answer.listen(a, "answer")
      client = Answer.dial(c, Answer.address(first))
      client_next = Answer.second_send_0(client, 23)
      on_b = pass(first, a, b, "to-b")
      on_d = pass(on_b, b, d, "to-d")
      :beam_session_probe.stop(a)
      :beam_session_probe.stop(b)
      {23, reply} = Answer.first_receive_0(on_d)
      Answer.first_send_1(reply, 46)
      {46, _} = Answer.second_receive_1(client_next)
      exchange = Exchange.listen(c, "data")
      receiving = Exchange.dial(d, Exchange.address(exchange))
      e1 = Exchange.first_send_0(exchange, {:just, [0, -7, 2_147_483_647]})
      {{:just, [0, -7, 2_147_483_647]}, e2} = Exchange.second_receive_0(receiving)
      Exchange.second_send_1(e2, :ok)
      {:ok, _} = Exchange.first_receive_1(e1)
      Answer.with_pair(fn local, peer ->
        remote = pass(local, c, d, "relay")
        peer_next = Answer.second_send_0(peer, 42)
        {42, remote_reply} = Answer.first_receive_0(remote)
        Answer.first_send_1(remote_reply, 84)
        {84, _} = Answer.second_receive_1(peer_next)
        true
      end)
    end)
  end
  defp pass(channel_end, a, b, name) do
    giving = Passing.listen(a, name)
    taking = Passing.dial(b, Passing.address(giving))
    Passing.first_send_0(giving, channel_end)
    {moved, _} = Passing.second_receive_0(taking)
    moved
  end
end
