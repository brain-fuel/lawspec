//! The Kafka reference model's workload, driven through the generated
//! `reference` spec handler of the Broker ability: produce across 100
//! partitions, a consumer group of ten members fetching and committing with a
//! rebalance, then transactions. See bench/README.md.
use lawspec_example::lawspec_abilities::lawtwin_kafka_contract::{Broker, Reference};
use lawspec_example::lawspec_data as data;
use lawspec_example::lawspec_runtime as ls;
use std::time::Instant;

const PARTITIONS: i32 = 100;
const MEMBERS: usize = 10;
const FETCH: i32 = 500;

fn tp(p: i32) -> data::TopicPartition {
    data::TopicPartition { topic: "bench".to_string(), partition: p }
}

fn record(i: u64) -> data::Record {
    data::Record { key: Some(i.to_be_bytes().to_vec()), value: Some(vec![b'x'; 64]), headers: vec![] }
}

fn right<A: std::fmt::Debug, B>(e: ls::Either<A, B>, what: &str) -> B {
    match e {
        ls::Either::Right(b) => b,
        ls::Either::Left(a) => panic!("{what}: {a:?}"),
    }
}

fn resident() -> u64 {
    let out = std::process::Command::new("ps").args(["-o", "rss=", "-p", &std::process::id().to_string()]).output().unwrap();
    String::from_utf8_lossy(&out.stdout).trim().parse::<u64>().unwrap_or(0) * 1024
}

fn phase(name: &str, ops: u64, start: Instant) {
    println!("phase {name} {ops} {:.6}", start.elapsed().as_secs_f64());
}

fn main() {
    let scale: u64 = std::env::args().nth(1).map(|s| s.parse().unwrap()).unwrap_or(1_000_000);
    // Deep but bounded recursion in the model's list walks.
    let worker = std::thread::Builder::new().stack_size(1 << 30).spawn(move || run(scale)).unwrap();
    worker.join().unwrap();
}

fn run(scale: u64) {
    let broker = Reference::new(&ls::Context::default());
    let all = Instant::now();
    let mut total = 0u64;
    right(broker.createTopicsRequest("bench".to_string(), PARTITIONS), "create topic");

    // Produce: one record per request, round robin over the partitions.
    let start = Instant::now();
    for i in 0..scale {
        right(broker.produceRequest(tp((i % PARTITIONS as u64) as i32), None, vec![record(i)]), "produce");
    }
    phase("produce", scale, start);
    total += scale;
    println!("memory after-produce {}", resident());

    // A group of ten: each join rebalances; every member syncs, then reads
    // its partitions in two rounds, committing after each fetch. Between the
    // rounds the last member leaves and rejoins.
    let start = Instant::now();
    let mut ops = 0u64;
    let members: Vec<String> = (0..MEMBERS).map(|m| format!("member-{m}")).collect();
    let mut generation = 0;
    for m in &members {
        generation = right(broker.joinGroupRequest("g".into(), m.clone(), vec!["bench".into()]), "join");
        ops += 1;
    }
    let mut read = 0u64;
    for round in 0..2 {
        if round == 1 {
            right(broker.leaveGroupRequest("g".into(), members[MEMBERS - 1].clone()), "leave");
            generation = right(broker.joinGroupRequest("g".into(), members[MEMBERS - 1].clone(), vec!["bench".into()]), "rejoin");
            ops += 2;
        }
        for m in &members {
            right(broker.heartbeatRequest("g".into(), m.clone(), generation), "heartbeat");
            let assigned = right(broker.syncGroupRequest("g".into(), m.clone(), generation), "sync");
            ops += 2;
            for p in assigned {
                let mut position = broker.offsetFetchRequest("g".into(), p.clone()).unwrap_or(0);
                ops += 1;
                loop {
                    let r = right(broker.fetchRequest(p.clone(), position, FETCH, data::IsolationLevel::ReadUncommitted), "fetch");
                    ops += 1;
                    let end = if round == 0 { r.highWatermark / 2 } else { r.highWatermark };
                    if r.records.is_empty() || position >= end {
                        break;
                    }
                    read += r.records.len() as u64;
                    position = r.nextOffset;
                    right(broker.offsetCommitRequest("g".into(), m.clone(), generation,
                        vec![data::OffsetEntry { topicPartition: p.clone(), offset: position }]), "commit");
                    ops += 1;
                }
            }
        }
    }
    phase("consume", ops, start);
    total += ops;
    println!("check records-read {read}");

    // Transactions: each adds two partitions, produces one record to each,
    // commits an offset and commits.
    let start = Instant::now();
    let mut ops = 0u64;
    let txns = (scale / 100).max(1);
    let id = right(broker.initProducerIdRequest(Some("tx".into())), "init producer");
    ops += 1;
    let mut sequences = vec![0i32; PARTITIONS as usize];
    for t in 0..txns {
        let parts = [((2 * t) % PARTITIONS as u64) as i32, ((2 * t + 1) % PARTITIONS as u64) as i32];
        right(broker.addPartitionsToTxnRequest("tx".into(), id.producerId, id.producerEpoch, parts.iter().map(|&p| tp(p)).collect()), "add partitions");
        for &p in &parts {
            let tag = data::ProducerTag { producerId: id.producerId, producerEpoch: id.producerEpoch, baseSequence: sequences[p as usize] };
            sequences[p as usize] += 1;
            right(broker.produceRequest(tp(p), Some(tag), vec![record(t)]), "transactional produce");
        }
        right(broker.txnOffsetCommitRequest("tx".into(), id.producerId, id.producerEpoch, "g".into(),
            vec![data::OffsetEntry { topicPartition: tp(parts[0]), offset: t as i64 }]), "txn offsets");
        right(broker.endTxnRequest("tx".into(), id.producerId, id.producerEpoch, true), "commit");
        ops += 5;
    }
    phase("transactions", ops, start);
    total += ops;
    let r = right(broker.fetchRequest(tp(0), 0, 10, data::IsolationLevel::ReadCommitted), "committed fetch");
    println!("check committed-hw {}", r.highWatermark);
    phase("total", total, all);
    println!("memory end {}", resident());
}
