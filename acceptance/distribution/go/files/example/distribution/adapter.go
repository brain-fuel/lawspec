// User-owned LawSpec adapter: the wire encoding, and nodes talking over
// in-memory, TCP and HTTP transports.
package distribution

import (
	"math/big"
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
