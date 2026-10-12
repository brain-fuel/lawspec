%% The Kafka reference model's workload, driven through the generated cluster
%% spec handler of the Broker ability: produce across 100 partitions, a
%% consumer group of ten members fetching and committing with a rebalance,
%% then transactions. See bench/README.md.
-module(kafka_bench).
-export([main/0, main/1]).

-define(PARTITIONS, 100).
-define(MEMBERS, 10).
-define(FETCH_MAX, 500).

main() -> main([]).

main(Args) ->
    Scale = case Args of
        [N | _] -> list_to_integer(N);
        [] -> 1000000
    end,
    lawspec_abilities:with_context(fun(Context) -> run(Context, Scale) end),
    halt(0).

tp(P) -> {topic_partition, <<"bench">>, P}.

record(I) -> {record, {just, <<I:64>>}, {just, binary:copy(<<"x">>, 64)}, []}.

op(Broker, Name, Args) -> erlang:apply(maps:get(Name, Broker), Args).

now_s() -> erlang:monotonic_time(microsecond) / 1.0e6.

phase(Name, Ops, Start) ->
    io:format("phase ~s ~b ~.6f~n", [Name, Ops, now_s() - Start]).

memory(Label) ->
    [erlang:garbage_collect(P) || P <- erlang:processes()],
    io:format("memory ~s ~b~n", [Label, erlang:memory(processes_used) + erlang:memory(binary)]).

run(Context, Scale) ->
    {Broker, _Admin, _Coordinator} = lawspec_abilities_lawtwin_kafka:cluster(Context),
    Everything = now_s(),
    op(Broker, create_topics_request, [<<"bench">>, ?PARTITIONS]),

    Start = now_s(),
    lists:foreach(fun(I) -> op(Broker, produce_request, [tp(I rem ?PARTITIONS), nothing, [record(I)]]) end,
        lists:seq(0, Scale - 1)),
    phase("produce", Scale, Start),
    memory("after-produce"),

    ConsumeStart = now_s(),
    Names = [iolist_to_binary(["member-", integer_to_list(M)]) || M <- lists:seq(0, ?MEMBERS - 1)],
    Joined = lists:foldl(fun(M, _) -> op(Broker, join_group_request, [<<"g">>, M, [<<"bench">>]]) end, 0, Names),
    {Read, ConsumeOps, _} = lists:foldl(fun(Round, {Read0, Ops0, Generation0}) ->
        {Generation, Ops1} = case Round of
            1 ->
                Last = lists:last(Names),
                op(Broker, leave_group_request, [<<"g">>, Last]),
                {op(Broker, join_group_request, [<<"g">>, Last, [<<"bench">>]]), Ops0 + 2};
            _ -> {Generation0, Ops0}
        end,
        {Read2, Ops2} = lists:foldl(fun(M, {R, O}) ->
            op(Broker, heartbeat_request, [<<"g">>, M, Generation]),
            Assigned = op(Broker, sync_group_request, [<<"g">>, M, Generation]),
            lists:foldl(fun(P, {R1, O1}) ->
                Position = case op(Broker, offset_fetch_request, [<<"g">>, P]) of
                    {just, V} -> V;
                    nothing -> 0
                end,
                consume(Broker, M, Generation, P, Position, Round, R1, O1 + 1)
            end, {R, O + 2}, Assigned)
        end, {Read0, Ops1}, Names),
        {Read2, Ops2, Generation}
    end, {0, ?MEMBERS, Joined}, [0, 1]),
    phase("consume", ConsumeOps, ConsumeStart),
    io:format("check records-read ~b~n", [Read]),

    TxnStart = now_s(),
    Txns = max(1, Scale div 100),
    {producer_id_and_epoch, Pid, Epoch} = op(Broker, init_producer_id_request, [{just, <<"tx">>}]),
    lists:foldl(fun(T, Sequences) ->
        Parts = [(2 * T) rem ?PARTITIONS, (2 * T + 1) rem ?PARTITIONS],
        op(Broker, add_partitions_to_txn_request, [<<"tx">>, Pid, Epoch, [tp(P) || P <- Parts]]),
        Next = lists:foldl(fun(P, S) ->
            Sequence = maps:get(P, S, 0),
            op(Broker, produce_request, [tp(P), {just, {producer_tag, Pid, Epoch, Sequence}}, [record(T)]]),
            S#{P => Sequence + 1}
        end, Sequences, Parts),
        op(Broker, txn_offset_commit_request, [<<"tx">>, Pid, Epoch, <<"g">>, [{offset_entry, tp(hd(Parts)), T}]]),
        op(Broker, end_txn_request, [<<"tx">>, Pid, Epoch, true]),
        Next
    end, #{}, lists:seq(0, Txns - 1)),
    TxnOps = 1 + 5 * Txns,
    phase("transactions", TxnOps, TxnStart),
    phase("total", Scale + ConsumeOps + TxnOps, Everything),
    memory("end"),
    {fetch_result, _, _, HighWatermark, _} = op(Broker, fetch_request, [tp(0), 0, 10, isolation_level_read_committed]),
    io:format("check committed-hw ~b~n", [HighWatermark]),

    %% The embedding API: a refusal as a value, and the state kept and put back.
    Refused = case lawspec_abilities_lawtwin_kafka:broker_try_produce_request(Broker,
            {topic_partition, <<"missing">>, 0}, nothing, [record(0)]) of
        {error, Failure} -> Failure;
        {ok, _} -> nothing
    end,
    io:format("check refused ~p~n", [Refused]),
    {Snapshot, Restore} = case erlang:function_exported(lawspec_abilities_lawtwin_kafka, cluster_typed_state, 1) of
        true -> {lawspec_abilities_lawtwin_kafka:cluster_typed_state(Broker),
            fun(S) -> lawspec_abilities_lawtwin_kafka:cluster_set_typed_state(Broker, S) end};
        false -> {lawspec_abilities_lawtwin_kafka:cluster_state(Broker),
            fun(S) -> lawspec_abilities_lawtwin_kafka:cluster_set_state(Broker, S) end}
    end,
    op(Broker, produce_request, [tp(0), nothing, [record(0)]]),
    ok = Restore(Snapshot),
    {fetch_result, _, _, After, _} = op(Broker, fetch_request, [tp(0), 0, 10, isolation_level_read_committed]),
    io:format("check restored ~p~n", [After =:= HighWatermark]),
    ok.

consume(Broker, M, Generation, P, Position, Round, Read, Ops) ->
    {fetch_result, Records, NextOffset, HighWatermark, _} =
        op(Broker, fetch_request, [P, Position, ?FETCH_MAX, isolation_level_read_uncommitted]),
    End = case Round of 1 -> HighWatermark; _ -> HighWatermark div 2 end,
    case Records =:= [] orelse Position >= End of
        true -> {Read, Ops + 1};
        false ->
            op(Broker, offset_commit_request, [<<"g">>, M, Generation, [{offset_entry, P, NextOffset}]]),
            consume(Broker, M, Generation, P, NextOffset, Round, Read + length(Records), Ops + 2)
    end.
