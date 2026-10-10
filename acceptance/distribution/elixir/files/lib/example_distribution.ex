# ref:DEC-tests-cite-requirements ref:DEC-distribution-canonical-wire
defmodule Example.Distribution do
  alias LawSpec.Network
  alias LawSpec.Remote.Example.Distribution, as: Remote
  alias LawSpec.Actors.Example.Distribution.TallyActor
  alias LawSpec.Actors.Example.Distribution.TallyActor.Remote, as: TallyActorRemote
  alias LawSpec.Mailboxes.Example.Distribution.LedgerMailbox
  alias LawSpec.Sessions.Example.Distribution.{Doubling, Handoff, Answering, Passing}
  alias LawSpec.Data.{Pair, Tally}

  def encoded(text, seed, size, count), do: :beam_distribution_support.encoded(text, seed, size, count)
  def round_trips(text, seed, size, count), do: :beam_distribution_support.round_trips(text, seed, size, count)
  def handshake_agrees(vector), do: :beam_distribution_support.handshake_agrees(vector)
  def open_tally(:ok), do: %Tally{count: 0}
  def add(%Tally{count: count}, value), do: %Pair{first: count + value, second: %Tally{count: count + value}}

  def remote_shifted(value) do
    Network.with_memory([seed: :beam_distribution_support.seed(value), loss: 0.2, duplicate: 0.2], fn net ->
      Network.with_node(Network.memory_transport(net, "here"), fn here ->
        Network.with_node(Network.memory_transport(net, "there"), fn there ->
          LawSpec.Remote.serve(there)
          Remote.shifted(here, Network.address(there), value)
        end)
      end)
    end)
  end

  def remote_adds(value) do
    with_sockets(:tcp, fn server, client ->
      TallyActor.with_actor(fn actor ->
        address = TallyActor.serve(actor, server, "tally")
        tally = TallyActorRemote.connect(client, address)
        TallyActorRemote.add(tally, value)
        TallyActorRemote.add(tally, value)
      end)
    end)
  end

  def remote_doubling(value) do
    with_sockets(:http, fn server, client ->
      first = Doubling.listen(server, "doubling")
      second = Doubling.dial(client, Doubling.address(first))
      task = Doubling.spawn_second(second, &double/1)
      :beam_distribution_support.with_task(task, fn -> answer(first, value) end)
    end)
  end
  defp double(channel_end) do
    {value, reply} = Doubling.second_receive_0(channel_end)
    Doubling.second_send_1(reply, 2 * value)
    :ok
  end
  defp answer(channel_end, value) do
    {result, _} = channel_end |> Doubling.first_send_0(value) |> Doubling.first_receive_1()
    result
  end

  def remote_ledger(value) do
    with_sockets(:tcp, fn server, client ->
      ledger = LedgerMailbox.serve(server, "ledger")
      try do
        sender = LedgerMailbox.connect(client, LedgerMailbox.address(ledger), 5000)
        :ok = LedgerMailbox.send_remote(sender, value)
        :ok = LedgerMailbox.send_remote(sender, value)
        total = LedgerMailbox.receive_value(ledger) + LedgerMailbox.receive_value(ledger)
        :nothing = LedgerMailbox.receive_within(ledger, 20000)
        total
      after
        LedgerMailbox.stop(ledger)
      end
    end)
  end

  def remote_handoff(value) do
    with_sockets(:tcp, fn here, there ->
      Doubling.with_pair(fn first, second ->
        task = Doubling.spawn_second(second, &double/1)
        :beam_distribution_support.with_task(task, fn ->
          giving = Handoff.listen(here, "handoff")
          taking = Handoff.dial(there, Handoff.address(giving))
          Handoff.first_send_0(giving, first)
          {channel_end, _} = Handoff.second_receive_0(taking)
          answer(channel_end, value)
        end)
      end)
    end)
  end

  def remote_handoff_onward(value) do
    Network.with_memory([seed: :beam_distribution_support.seed(value), loss: 0.1, duplicate: 0.1, delay: 0.005], fn net ->
      with_memory_nodes(net, ["a", "b", "c", "d"], fn [a, b, c, d] ->
        first = Answering.listen(a, "answering")
        second = c |> Answering.dial(Answering.address(first)) |> Answering.second_send_0(value)
        giving_b = Passing.listen(a, "to-b")
        taking_b = Passing.dial(b, Passing.address(giving_b))
        Passing.first_send_0(giving_b, first)
        {moved, _} = Passing.second_receive_0(taking_b)
        giving_d = Passing.listen(b, "to-d")
        taking_d = Passing.dial(d, Passing.address(giving_d))
        Passing.first_send_0(giving_d, moved)
        {channel_end, _} = Passing.second_receive_0(taking_d)
        :ok = Network.close(a)
        :ok = Network.close(b)
        {input, reply} = Answering.first_receive_0(channel_end)
        Answering.first_send_1(reply, 2 * input)
        {result, _} = Answering.second_receive_1(second)
        result
      end)
    end)
  end
  defp with_memory_nodes(_net, [], body), do: body.([])
  defp with_memory_nodes(net, [name | names], body) do
    Network.with_node(Network.memory_transport(net, name), fn node ->
      with_memory_nodes(net, names, fn nodes -> body.([node | nodes]) end)
    end)
  end

  def sealed_on_the_wire(value) do
    digest = LawSpec.Remote.digest("example.distribution::shifted")
    Enum.all?([false, true], fn insecure ->
      Network.with_memory([seed: :beam_distribution_support.seed(value), record: true], fn net ->
        make = if insecure, do: &Network.insecure_memory_transport_for_tests/2, else: &Network.memory_transport/2
        Network.with_node(make.(net, "here"), fn here ->
          Network.with_node(make.(net, "there"), fn there ->
            LawSpec.Remote.serve(there)
            Remote.shifted(here, Network.address(there), value) == value + 1000 and
              :beam_distribution_support.contains_frame(net, digest) == insecure
          end)
        end)
      end)
    end)
  end

  defp with_sockets(kind, body) do
    transport = case kind do
      :tcp -> Network.tcp("127.0.0.1", 0)
      :http -> Network.http("127.0.0.1", 0)
    end
    Network.with_node(transport, fn server ->
      Network.with_node(transport, fn client -> body.(server, client) end)
    end)
  end
end
