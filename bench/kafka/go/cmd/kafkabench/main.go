// The Kafka reference model's workload, driven through the generated
// cluster spec handler of the Broker ability: produce across 100
// partitions, a consumer group of ten members fetching and committing with a
// rebalance, then transactions. See bench/README.md.
package main

import (
	"encoding/binary"
	"fmt"
	"os"
	"runtime"
	"runtime/debug"
	"strconv"
	"time"

	kafka "example.com/lawspec-example/lawtwin/kafka"
)

const (
	partitions = 100
	members    = 10
	fetchMax   = 500
)

func tp(p int) kafka.TopicPartition { return kafka.TopicPartition{Topic: "bench", Partition: int32(p)} }

func record(i uint64) kafka.Record {
	key := make([]byte, 8)
	binary.BigEndian.PutUint64(key, i)
	value := make([]byte, 64)
	for j := range value {
		value[j] = 'x'
	}
	return kafka.Record{Key: kafka.LawSpecJust(key), Value: kafka.LawSpecJust(value)}
}

func phase(name string, ops uint64, start time.Time) {
	fmt.Printf("phase %s %d %.6f\n", name, ops, time.Since(start).Seconds())
}

func memory(label string) {
	runtime.GC()
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	fmt.Printf("memory %s %d\n", label, m.HeapAlloc)
}

func main() {
	scale := uint64(1000000)
	if len(os.Args) > 1 {
		scale, _ = strconv.ParseUint(os.Args[1], 10, 64)
	}
	debug.SetMaxStack(1 << 30)
	broker := kafka.StartCluster()
	all := time.Now()
	var total uint64
	broker.CreateTopicsRequest("bench", partitions)

	start := time.Now()
	for i := uint64(0); i < scale; i++ {
		broker.ProduceRequest(tp(int(i%partitions)), kafka.LawSpecNothing[kafka.ProducerTag](), []kafka.Record{record(i)})
	}
	phase("produce", scale, start)
	total += scale
	memory("after-produce")

	start = time.Now()
	var ops uint64
	names := make([]string, members)
	for m := range names {
		names[m] = fmt.Sprintf("member-%d", m)
	}
	var generation int32
	for _, m := range names {
		generation = broker.JoinGroupRequest("g", m, []string{"bench"})
		ops++
	}
	var read uint64
	for round := 0; round < 2; round++ {
		if round == 1 {
			broker.LeaveGroupRequest("g", names[members-1])
			generation = broker.JoinGroupRequest("g", names[members-1], []string{"bench"})
			ops += 2
		}
		for _, m := range names {
			broker.HeartbeatRequest("g", m, generation)
			assigned := broker.SyncGroupRequest("g", m, generation)
			ops += 2
			for _, p := range assigned {
				position, _ := broker.OffsetFetchRequest("g", p).Value()
				ops++
				for {
					r := broker.FetchRequest(p, position, fetchMax, kafka.IsolationLevelReadUncommitted{})
					ops++
					end := r.HighWatermark
					if round == 0 {
						end = r.HighWatermark / 2
					}
					if len(r.Records) == 0 || position >= end {
						break
					}
					read += uint64(len(r.Records))
					position = r.NextOffset
					broker.OffsetCommitRequest("g", m, generation, []kafka.OffsetEntry{{TopicPartition: p, Offset: position}})
					ops++
				}
			}
		}
	}
	phase("consume", ops, start)
	total += ops
	fmt.Printf("check records-read %d\n", read)

	start = time.Now()
	ops = 0
	txns := scale / 100
	if txns == 0 {
		txns = 1
	}
	id := broker.InitProducerIdRequest(kafka.LawSpecJust("tx"))
	ops++
	sequences := make([]int32, partitions)
	for t := uint64(0); t < txns; t++ {
		parts := []int{int((2 * t) % partitions), int((2*t + 1) % partitions)}
		broker.AddPartitionsToTxnRequest("tx", id.ProducerId, id.ProducerEpoch, []kafka.TopicPartition{tp(parts[0]), tp(parts[1])})
		for _, p := range parts {
			tag := kafka.ProducerTag{ProducerId: id.ProducerId, ProducerEpoch: id.ProducerEpoch, BaseSequence: sequences[p]}
			sequences[p]++
			broker.ProduceRequest(tp(p), kafka.LawSpecJust(tag), []kafka.Record{record(t)})
		}
		broker.TxnOffsetCommitRequest("tx", id.ProducerId, id.ProducerEpoch, "g", []kafka.OffsetEntry{{TopicPartition: tp(parts[0]), Offset: int64(t)}})
		broker.EndTxnRequest("tx", id.ProducerId, id.ProducerEpoch, true)
		ops += 5
	}
	phase("transactions", ops, start)
	total += ops
	phase("total", total, all)
	memory("end")
	r := broker.FetchRequest(tp(0), 0, 10, kafka.IsolationLevelReadCommitted{})
	fmt.Printf("check committed-hw %d\n", r.HighWatermark)
}
