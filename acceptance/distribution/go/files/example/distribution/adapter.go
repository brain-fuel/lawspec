// User-owned LawSpec adapter: the wire encoding, and nodes talking over
// in-memory, TCP and HTTP transports.
package distribution

import (
	"bytes"
	"math/big"
	"strings"
	"time"
)

// Encoded is the wire encoding's conformance vectors.
func Encoded(value0 string, value1 uint64, value2 int32, value3 int32) []string {
	return LawSpecWireEncoded(value0, value1, int64(value2), int64(value3))
}

// RoundTrips is whether generated values decode to themselves.
func RoundTrips(value0 string, value1 uint64, value2 int32, value3 int32) bool {
	return LawSpecWireRoundTrips(value0, value1, int64(value2), int64(value3))
}

// RemoteShifted evaluates shifted on another node over a lossy network.
func RemoteShifted(value0 int32) LawSpecTask[int64] {
	return LawSpecGo(func() int64 { return remoteShifted(value0) })
}

func remoteShifted(value0 int32) int64 {
	network := NewLawSpecMemoryNetwork(uint64(value0)&0xFFFF, 0.2, 0.2, 0)
	here := NewLawSpecNode(network.Transport("here"))
	there := NewLawSpecNode(network.Transport("there"))
	defer here.Close()
	defer there.Close()
	if _, err := LawSpecServeDefinitions(there); err != nil {
		panic(err)
	}
	result, err := LawSpecEvaluateRemote(here, there.Address(), "example.distribution::shifted", 5*time.Second, lsFromNative("Int32", value0, 64))
	if err != nil {
		panic(err)
	}
	return result.Data.(*big.Int).Int64()
}

// OpenTally makes a tally at zero.
func OpenTally(value0 LawSpecValue) Tally {
	return Tally{Count: 0}
}

// Add adds to the tally and replies with the new count.
func Add(value0 Tally, value1 uint8) Pair[int64, Tally] {
	after := value0.Count + int64(value1)
	return Pair[int64, Tally]{First: after, Second: Tally{Count: after}}
}

func tcpNode() *LawSpecNode {
	transport, err := NewLawSpecTcpTransport("127.0.0.1", 0)
	if err != nil {
		panic(err)
	}
	return NewLawSpecNode(transport)
}

func httpNode() *LawSpecNode {
	transport, err := NewLawSpecHttpTransport("127.0.0.1", 0)
	if err != nil {
		panic(err)
	}
	return NewLawSpecNode(transport)
}

// RemoteAdds serves a tally on one node and adds to it twice from another.
func RemoteAdds(value0 uint8) LawSpecTask[int64] {
	return LawSpecGo(func() int64 { return remoteAdds(value0) })
}

func remoteAdds(value0 uint8) int64 {
	server, client := tcpNode(), tcpNode()
	defer client.Close()
	defer server.Close()
	address, err := StartTallyActor().Serve(server, "tally")
	if err != nil {
		panic(err)
	}
	tally := ConnectTallyActor(client, address, 5*time.Second)
	if _, err := tally.Add(value0); err != nil {
		panic(err)
	}
	total, err := tally.Add(value0)
	if err != nil {
		panic(err)
	}
	return total
}

// RemoteDoubling has one node send a number to another, which replies with
// its double.
func RemoteDoubling(value0 int32) LawSpecTask[int64] {
	return LawSpecGo(func() int64 { return remoteDoubling(value0) })
}

func remoteDoubling(value0 int32) int64 {
	server, client := httpNode(), httpNode()
	defer client.Close()
	defer server.Close()
	first, err := ListenDoubling(server, "doubling")
	if err != nil {
		panic(err)
	}
	second, err := DialDoubling(client, server.Address()+"/doubling")
	if err != nil {
		panic(err)
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		x, reply := second.Receive()
		reply.Send(2 * int64(x))
	}()
	result, _ := first.Send(value0).Receive()
	<-done
	return result
}

// RemoteLedger sends x twice to a mailbox on another node and sums what
// the mailbox received.
func RemoteLedger(value0 int32) LawSpecTask[int64] {
	return LawSpecGo(func() int64 { return remoteLedger(value0) })
}

func remoteLedger(value0 int32) int64 {
	here, there := tcpNode(), tcpNode()
	defer here.Close()
	defer there.Close()
	ledger, err := ServeLedgerMailbox(there, "ledger")
	if err != nil {
		panic(err)
	}
	sender := ConnectLedgerMailbox(here, there.Address()+"/ledger", 5*time.Second)
	for i := 0; i < 2; i++ {
		if err := sender.Send(int64(value0)); err != nil {
			panic(err)
		}
	}
	a, err := ledger.Receive(5 * time.Second)
	if err != nil {
		panic(err)
	}
	b, err := ledger.Receive(5 * time.Second)
	if err != nil {
		panic(err)
	}
	// Receive within: nothing more comes, so it gives none in time.
	if _, ok, err := ledger.ReceiveWithin(20 * time.Millisecond); err != nil || ok {
		return -1
	}
	return a + b
}

// RemoteHandoff hands a local channel end to another node, which uses it
// through this node's relay.
func RemoteHandoff(value0 int32) LawSpecTask[int64] {
	return LawSpecGo(func() int64 { return remoteHandoff(value0) })
}

func remoteHandoff(value0 int32) int64 {
	here, there := tcpNode(), tcpNode()
	defer there.Close()
	defer here.Close()
	first, second := OpenDoubling()
	done := make(chan struct{})
	go func() {
		defer close(done)
		x, reply := second.Receive()
		reply.Send(2 * int64(x))
	}()
	giving, err := ListenHandoff(here, "handoff")
	if err != nil {
		panic(err)
	}
	taking, err := DialHandoff(there, here.Address()+"/handoff")
	if err != nil {
		panic(err)
	}
	giving.Send(first)
	end, _ := taking.Receive()
	result, _ := end.Send(value0).Receive()
	<-done
	return result
}

// RemoteHandoffOnward moves an end whose peer is on node C from A to B and
// on to D over a faulty network; then A and B close and C and D finish.
func RemoteHandoffOnward(value0 int32) LawSpecTask[int64] {
	return LawSpecGo(func() int64 { return remoteHandoffOnward(value0) })
}

func remoteHandoffOnward(value0 int32) int64 {
	network := NewLawSpecMemoryNetwork(uint64(value0)&0xFFFF, 0.1, 0.1, 5*time.Millisecond)
	a := NewLawSpecNode(network.Transport("a"))
	b := NewLawSpecNode(network.Transport("b"))
	c := NewLawSpecNode(network.Transport("c"))
	d := NewLawSpecNode(network.Transport("d"))
	for _, node := range []*LawSpecNode{a, b, c, d} {
		defer node.Close()
	}
	must := func(err error) {
		if err != nil {
			panic(err)
		}
	}
	// A conversation between A and C, which sends at once; A's end moves to
	// B, then to D, and answers from there.
	first, err := ListenAnswering(a, "answering")
	must(err)
	dialled, err := DialAnswering(c, a.Address()+"/answering")
	must(err)
	second := dialled.Send(value0)
	toB, err := ListenPassing(a, "to-b")
	must(err)
	atB, err := DialPassing(b, a.Address()+"/to-b")
	must(err)
	toB.Send(first)
	moved, _ := atB.Receive()
	toD, err := ListenPassing(b, "to-d")
	must(err)
	atD, err := DialPassing(d, b.Address()+"/to-d")
	must(err)
	toD.Send(moved)
	end, _ := atD.Receive()
	// The end no longer needs A or B.
	a.Close()
	b.Close()
	x, reply := end.Receive()
	reply.Send(2 * int64(x))
	result, _ := second.Receive()
	return result
}

// SealedOnTheWire evaluates shifted on another node, first over the secure
// network and then over the transport made for tests only: the request
// names the definition's content hash, which shows on the wire only in the
// clear.
func SealedOnTheWire(value0 int32) LawSpecTask[bool] {
	return LawSpecGo(func() bool { return sealedOnTheWire(value0) })
}

func sealedOnTheWire(value0 int32) bool {
	name := "example.distribution::shifted"
	digest := []byte(LawSpecDefinitionDigest(name))
	seen := map[bool]bool{}
	for _, insecure := range []bool{false, true} {
		network := NewLawSpecMemoryNetwork(uint64(value0)&0xFFFF, 0, 0, 0).Record()
		transport := network.Transport
		if insecure {
			transport = network.InsecureTransportForTests
		}
		here, there := NewLawSpecNode(transport("here")), NewLawSpecNode(transport("there"))
		shifted := func() bool {
			defer here.Close()
			defer there.Close()
			if _, err := LawSpecServeDefinitions(there); err != nil {
				panic(err)
			}
			result, err := LawSpecEvaluateRemote(here, there.Address(), name, 5*time.Second, lsFromNative("Int32", value0, 64))
			if err != nil {
				panic(err)
			}
			return result.Data.(*big.Int).Int64() == int64(value0)+1000
		}()
		if !shifted {
			return false
		}
		for _, record := range network.Recorded() {
			if bytes.Contains(record, digest) {
				seen[insecure] = true
			}
		}
	}
	return !seen[false] && seen[true]
}

// HandshakeAgrees checks the handshake vector: its 13 fields, separated by
// single spaces.
func HandshakeAgrees(value0 string) bool {
	f := strings.Split(value0, " ")
	if len(f) != 13 {
		return false
	}
	return LawSpecHandshakeVector(f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10], f[11], f[12])
}
