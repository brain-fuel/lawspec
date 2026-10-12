//// The Kafka reference model's workload, driven through the generated
//// cluster spec handler of the Broker ability: produce across 100
//// partitions, a consumer group of ten members fetching and committing with
//// a rebalance, then transactions. See bench/README.md.

import gleam/dict
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lawspec/abilities/lawtwin/kafka as abilities
import lawspec/data
import lawspec/effects

const partitions = 100

const members = 10

const fetch_max = 500

@external(erlang, "kafka_bench_ffi", "scale")
fn scale() -> Int

@external(erlang, "kafka_bench_ffi", "now")
fn now() -> Int

@external(erlang, "kafka_bench_ffi", "seconds")
fn seconds(micros: Int) -> String

@external(erlang, "kafka_bench_ffi", "memory")
fn memory_bytes() -> Int

pub fn main() -> Nil {
  let n = scale()
  effects.with_context(fn(context) { run(context, n) })
}

fn tp(p: Int) -> data.TopicPartition {
  data.TopicPartition(topic: "bench", partition: p)
}

fn record(i: Int) -> data.Record {
  data.Record(
    key: Some(<<i:size(64)>>),
    value: Some(<<string.repeat("x", 64):utf8>>),
    headers: [],
  )
}

fn phase(name: String, ops: Int, start: Int) -> Nil {
  io.println(
    "phase " <> name <> " " <> int.to_string(ops) <> " " <> seconds(now() - start),
  )
}

fn memory(label: String) -> Nil {
  io.println("memory " <> label <> " " <> int.to_string(memory_bytes()))
}

fn run(context: effects.Context, n: Int) -> Nil {
  let #(broker, _admin, _coordinator) = abilities.cluster(context)
  let everything = now()
  abilities.broker_create_topics_request(broker, "bench", partitions)

  let start = now()
  int.range(from: 0, to: n, with: Nil, run: fn(_, i) {
    abilities.broker_produce_request(broker, tp(i % partitions), None, [
      record(i),
    ])
    Nil
  })
  phase("produce", n, start)
  memory("after-produce")

  let start = now()
  let names =
    int.range(from: 0, to: members, with: [], run: fn(acc, m) {
      ["member-" <> int.to_string(m), ..acc]
    })
    |> list.reverse
  let joined =
    list.fold(names, 0, fn(_, m) {
      abilities.broker_join_group_request(broker, "g", m, ["bench"])
    })
  let #(read, ops, _) =
    list.fold([0, 1], #(0, members, joined), fn(acc, round) {
      let #(read, ops, generation) = acc
      let #(generation, ops) = case round {
        1 -> {
          let assert Ok(last) = list.last(names)
          abilities.broker_leave_group_request(broker, "g", last)
          #(
            abilities.broker_join_group_request(broker, "g", last, ["bench"]),
            ops + 2,
          )
        }
        _ -> #(generation, ops)
      }
      let #(read, ops) =
        list.fold(names, #(read, ops), fn(acc, m) {
          let #(read, ops) = acc
          abilities.broker_heartbeat_request(broker, "g", m, generation)
          let assigned =
            abilities.broker_sync_group_request(broker, "g", m, generation)
          list.fold(assigned, #(read, ops + 2), fn(acc, p) {
            let #(read, ops) = acc
            let position = case
              abilities.broker_offset_fetch_request(broker, "g", p)
            {
              Some(v) -> v
              None -> 0
            }
            consume(broker, m, generation, p, position, round, read, ops + 1)
          })
        })
      #(read, ops, generation)
    })
  phase("consume", ops, start)
  io.println("check records-read " <> int.to_string(read))

  let start = now()
  let txns = int.max(1, n / 100)
  let data.ProducerIdAndEpoch(producer_id: pid, producer_epoch: epoch) =
    abilities.broker_init_producer_id_request(broker, Some("tx"))
  int.range(from: 0, to: txns, with: dict.new(), run: fn(sequences, t) {
    let parts = [{ 2 * t } % partitions, { 2 * t + 1 } % partitions]
    abilities.broker_add_partitions_to_txn_request(
      broker,
      "tx",
      pid,
      epoch,
      list.map(parts, tp),
    )
    let sequences =
      list.fold(parts, sequences, fn(s, p) {
        let sequence = case dict.get(s, p) {
          Ok(v) -> v
          Error(_) -> 0
        }
        let tag =
          data.ProducerTag(
            producer_id: pid,
            producer_epoch: epoch,
            base_sequence: sequence,
          )
        abilities.broker_produce_request(broker, tp(p), Some(tag), [record(t)])
        dict.insert(s, p, sequence + 1)
      })
    let assert [first, ..] = parts
    abilities.broker_txn_offset_commit_request(broker, "tx", pid, epoch, "g", [
      data.OffsetEntry(topic_partition: tp(first), offset: t),
    ])
    abilities.broker_end_txn_request(broker, "tx", pid, epoch, True)
    sequences
  })
  let txn_ops = 1 + 5 * txns
  phase("transactions", txn_ops, start)
  phase("total", n + ops + txn_ops, everything)
  memory("end")
  let result =
    abilities.broker_fetch_request(
      broker,
      tp(0),
      0,
      10,
      data.IsolationLevelReadCommitted,
    )
  io.println("check committed-hw " <> int.to_string(result.high_watermark))

  // The embedding API: a refusal as a value, and the state kept and put back.
  let refused = case
    abilities.broker_try_produce_request(
      broker,
      data.TopicPartition(topic: "missing", partition: 0),
      None,
      [record(0)],
    )
  {
    Error(failure) -> string.inspect(failure)
    Ok(_) -> "nothing"
  }
  io.println("check refused " <> refused)
  let snapshot = abilities.cluster_typed_state(broker)
  abilities.broker_produce_request(broker, tp(0), None, [record(0)])
  abilities.cluster_set_typed_state(broker, snapshot)
  let after =
    abilities.broker_fetch_request(
      broker,
      tp(0),
      0,
      10,
      data.IsolationLevelReadCommitted,
    )
  io.println(
    "check restored "
    <> case after.high_watermark == result.high_watermark {
      True -> "true"
      False -> "false"
    },
  )
}

fn consume(
  broker: abilities.Broker,
  m: String,
  generation: Int,
  p: data.TopicPartition,
  position: Int,
  round: Int,
  read: Int,
  ops: Int,
) -> #(Int, Int) {
  let result =
    abilities.broker_fetch_request(
      broker,
      p,
      position,
      fetch_max,
      data.IsolationLevelReadUncommitted,
    )
  let stop = case round {
    1 -> result.high_watermark
    _ -> result.high_watermark / 2
  }
  case result.records == [] || position >= stop {
    True -> #(read, ops + 1)
    False -> {
      abilities.broker_offset_commit_request(broker, "g", m, generation, [
        data.OffsetEntry(topic_partition: p, offset: result.next_offset),
      ])
      consume(
        broker,
        m,
        generation,
        p,
        result.next_offset,
        round,
        read + list.length(result.records),
        ops + 2,
      )
    }
  }
}
