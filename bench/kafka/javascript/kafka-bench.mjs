// The Kafka reference model's workload, driven through the generated
// cluster spec handler of the Broker ability: produce across 100
// partitions, a consumer group of ten members fetching and committing with a
// rebalance, then transactions. See bench/README.md.
import * as data from './src/lawspec_data.mjs';
import { Cluster } from './src/lawspec_abilities/lawtwin/kafka.mjs';

const PARTITIONS = 100;
const MEMBERS = 10;
const FETCH_MAX = 500;

const tp = (p) => new data.TopicPartition('bench', p);
const payload = new Uint8Array(64).fill(120);
function record(i) {
  const key = new Uint8Array(8);
  new DataView(key.buffer).setBigUint64(0, BigInt(i));
  return new data.Record(new data.Just(key), new data.Just(payload.slice()), []);
}
const now = () => Number(process.hrtime.bigint()) / 1e9;
const phase = (name, ops, start) => console.log(`phase ${name} ${ops} ${(now() - start).toFixed(6)}`);
function memory(label) {
  if (globalThis.gc) globalThis.gc();
  console.log(`memory ${label} ${process.memoryUsage().heapUsed}`);
}

const args = process.argv.slice(2).filter((a) => !a.startsWith('--'));
const scale = args.length > 0 ? Number(args[0]) : 1000000;
const broker = new Cluster();
const all = now();
let total = 0;
broker.createTopicsRequest('bench', PARTITIONS);

let start = now();
const nothing = new data.Nothing();
for (let i = 0; i < scale; i++) broker.produceRequest(tp(i % PARTITIONS), nothing, [record(i)]);
phase('produce', scale, start);
total += scale;
memory('after-produce');

start = now();
let ops = 0;
const names = Array.from({ length: MEMBERS }, (_, m) => `member-${m}`);
let generation = 0;
for (const m of names) {
  generation = broker.joinGroupRequest('g', m, ['bench']);
  ops++;
}
let read = 0;
const uncommitted = new data.IsolationLevelReadUncommitted();
for (let round = 0; round < 2; round++) {
  if (round === 1) {
    broker.leaveGroupRequest('g', names[MEMBERS - 1]);
    generation = broker.joinGroupRequest('g', names[MEMBERS - 1], ['bench']);
    ops += 2;
  }
  for (const m of names) {
    broker.heartbeatRequest('g', m, generation);
    const assigned = broker.syncGroupRequest('g', m, generation);
    ops += 2;
    for (const p of assigned) {
      const fetched = broker.offsetFetchRequest('g', p);
      let position = fetched instanceof data.Just ? fetched.value : 0n;
      ops++;
      for (;;) {
        const r = broker.fetchRequest(p, position, FETCH_MAX, uncommitted);
        ops++;
        const end = round === 0 ? r.highWatermark / 2n : r.highWatermark;
        if (r.records.length === 0 || position >= end) break;
        read += r.records.length;
        position = r.nextOffset;
        broker.offsetCommitRequest('g', m, generation, [new data.OffsetEntry(p, position)]);
        ops++;
      }
    }
  }
}
phase('consume', ops, start);
total += ops;
console.log(`check records-read ${read}`);

start = now();
ops = 0;
const txns = Math.max(1, Math.floor(scale / 100));
const id = broker.initProducerIdRequest(new data.Just('tx'));
ops++;
const sequences = new Array(PARTITIONS).fill(0);
for (let t = 0; t < txns; t++) {
  const parts = [(2 * t) % PARTITIONS, (2 * t + 1) % PARTITIONS];
  broker.addPartitionsToTxnRequest('tx', id.producerId, id.producerEpoch, [tp(parts[0]), tp(parts[1])]);
  for (const p of parts) {
    const tag = new data.ProducerTag(id.producerId, id.producerEpoch, sequences[p]++);
    broker.produceRequest(tp(p), new data.Just(tag), [record(t)]);
  }
  broker.txnOffsetCommitRequest('tx', id.producerId, id.producerEpoch, 'g', [new data.OffsetEntry(tp(parts[0]), BigInt(t))]);
  broker.endTxnRequest('tx', id.producerId, id.producerEpoch, true);
  ops += 5;
}
phase('transactions', ops, start);
total += ops;
phase('total', total, all);
memory('end');
const last = broker.fetchRequest(tp(0), 0n, 10, new data.IsolationLevelReadCommitted());
console.log(`check committed-hw ${last.highWatermark}`);

// The embedding API: a refusal as a value, and the state kept and put back.
const refused = (broker).tryProduceRequest(new data.TopicPartition('missing', 0), nothing, [record(0)]);
console.log(`check refused ${refused instanceof data.Left ? refused.value.constructor.name : 'nothing'}`);
const snapshot = (broker).typedState();
broker.produceRequest(tp(0), nothing, [record(0)]);
(broker).setTypedState(snapshot);
const after = broker.fetchRequest(tp(0), 0n, 10, new data.IsolationLevelReadCommitted());
console.log(`check restored ${after.highWatermark === last.highWatermark}`);
