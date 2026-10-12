defmodule KafkaBench do
  @moduledoc """
  The Kafka reference model's workload, driven through the generated cluster
  spec handler of the Broker ability: produce across 100 partitions, a
  consumer group of ten members fetching and committing with a rebalance,
  then transactions. See bench/README.md.
  """

  alias LawSpec.Abilities.Lawtwin.Kafka.Broker
  alias LawSpec.Data.{FetchResult, OffsetEntry, ProducerIdAndEpoch, ProducerTag, Record, TopicPartition}
  alias LawSpec.Handlers.LawtwinKafka, as: Handlers

  @partitions 100
  @members 10
  @fetch_max 500

  def main(args) do
    scale =
      case args do
        [n | _] -> String.to_integer(n)
        [] -> 1_000_000
      end

    :lawspec_abilities.with_context(fn context -> run(context, scale) end)
  end

  defp tp(p), do: %TopicPartition{topic: "bench", partition: p}

  defp record(i), do: %Record{key: {:just, <<i::64>>}, value: {:just, String.duplicate("x", 64)}, headers: []}

  defp now, do: System.monotonic_time(:microsecond) / 1.0e6

  defp phase(name, ops, start), do: IO.puts("phase #{name} #{ops} #{:erlang.float_to_binary(now() - start, decimals: 6)}")

  defp memory(label) do
    Enum.each(Process.list(), &:erlang.garbage_collect/1)
    IO.puts("memory #{label} #{:erlang.memory(:processes_used) + :erlang.memory(:binary)}")
  end

  defp run(context, scale) do
    {broker, _admin, _coordinator} = Handlers.cluster(context)
    everything = now()
    broker.create_topics_request.("bench", @partitions)

    start = now()
    Enum.each(0..(scale - 1)//1, fn i -> broker.produce_request.(tp(rem(i, @partitions)), :nothing, [record(i)]) end)
    phase("produce", scale, start)
    memory("after-produce")

    start = now()
    names = for m <- 0..(@members - 1), do: "member-#{m}"
    joined = Enum.reduce(names, 0, fn m, _ -> broker.join_group_request.("g", m, ["bench"]) end)

    {read, ops, _} =
      Enum.reduce([0, 1], {0, @members, joined}, fn round, {read, ops, generation} ->
        {generation, ops} =
          if round == 1 do
            last = List.last(names)
            broker.leave_group_request.("g", last)
            {broker.join_group_request.("g", last, ["bench"]), ops + 2}
          else
            {generation, ops}
          end

        {read, ops} =
          Enum.reduce(names, {read, ops}, fn m, {read, ops} ->
            broker.heartbeat_request.("g", m, generation)
            assigned = broker.sync_group_request.("g", m, generation)

            Enum.reduce(assigned, {read, ops + 2}, fn p, {read, ops} ->
              position =
                case broker.offset_fetch_request.("g", p) do
                  {:just, v} -> v
                  :nothing -> 0
                end

              consume(broker, m, generation, p, position, round, read, ops + 1)
            end)
          end)

        {read, ops, generation}
      end)

    phase("consume", ops, start)
    IO.puts("check records-read #{read}")

    start = now()
    txns = max(1, div(scale, 100))
    %ProducerIdAndEpoch{producer_id: pid, producer_epoch: epoch} = broker.init_producer_id_request.({:just, "tx"})

    Enum.reduce(0..(txns - 1)//1, %{}, fn t, sequences ->
      parts = [rem(2 * t, @partitions), rem(2 * t + 1, @partitions)]
      broker.add_partitions_to_txn_request.("tx", pid, epoch, Enum.map(parts, &tp/1))

      sequences =
        Enum.reduce(parts, sequences, fn p, s ->
          sequence = Map.get(s, p, 0)
          tag = %ProducerTag{producer_id: pid, producer_epoch: epoch, base_sequence: sequence}
          broker.produce_request.(tp(p), {:just, tag}, [record(t)])
          Map.put(s, p, sequence + 1)
        end)

      broker.txn_offset_commit_request.("tx", pid, epoch, "g", [%OffsetEntry{topic_partition: tp(hd(parts)), offset: t}])
      broker.end_txn_request.("tx", pid, epoch, true)
      sequences
    end)

    txn_ops = 1 + 5 * txns
    phase("transactions", txn_ops, start)
    phase("total", scale + ops + txn_ops, everything)
    memory("end")
    committed = %LawSpec.Data.IsolationLevelReadCommitted{}
    %FetchResult{high_watermark: hw} = broker.fetch_request.(tp(0), 0, 10, committed)
    IO.puts("check committed-hw #{hw}")

    # The embedding API: a refusal as a value, and the state kept and put back.
    refused =
      case Broker.try_produce_request(broker, %TopicPartition{topic: "missing", partition: 0}, :nothing, [record(0)]) do
        {:error, failure} -> inspect(failure.__struct__)
        {:ok, _} -> "nothing"
      end

    IO.puts("check refused #{refused}")

    {snapshot, restore} =
      if function_exported?(Handlers, :cluster_typed_state, 1) do
        {Handlers.cluster_typed_state(broker), &Handlers.cluster_set_typed_state(broker, &1)}
      else
        {Handlers.cluster_state(broker), &Handlers.cluster_set_state(broker, &1)}
      end

    broker.produce_request.(tp(0), :nothing, [record(0)])
    :ok = restore.(snapshot)
    %FetchResult{high_watermark: after_hw} = broker.fetch_request.(tp(0), 0, 10, committed)
    IO.puts("check restored #{after_hw == hw}")
  end

  defp consume(broker, m, generation, p, position, round, read, ops) do
    uncommitted = %LawSpec.Data.IsolationLevelReadUncommitted{}
    %FetchResult{records: records, next_offset: next, high_watermark: hw} = broker.fetch_request.(p, position, @fetch_max, uncommitted)
    stop = if round == 1, do: hw, else: div(hw, 2)

    if records == [] or position >= stop do
      {read, ops + 1}
    else
      broker.offset_commit_request.("g", m, generation, [%OffsetEntry{topic_partition: p, offset: next}])
      consume(broker, m, generation, p, next, round, read + length(records), ops + 2)
    end
  end
end
