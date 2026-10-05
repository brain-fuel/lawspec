// User-owned LawSpec adapter: a page-view counter with one replica per
// goroutine.
package consistency

import (
	"runtime"
	"strings"
	"sync"
)

var (
	lock     sync.Mutex
	replicas = map[int32]map[string]int64{}
	ids      int32
)

// caller names the goroutine making the call.
func caller() string {
	buffer := make([]byte, 64)
	header := string(buffer[:runtime.Stack(buffer, false)])
	return strings.Fields(header)[1]
}

// NewViews makes a counter with no replicas yet.
func NewViews(value0 LawSpecValue) Views {
	lock.Lock()
	defer lock.Unlock()
	ids++
	replicas[ids] = map[string]int64{}
	return Views{Id: ids}
}

// Hit counts on the caller's replica and returns what it has seen.
func Hit(value0 Views) int64 {
	lock.Lock()
	defer lock.Unlock()
	mine := replicas[value0.Id]
	me := caller()
	mine[me]++
	return mine[me]
}

// Total sums the replicas.
func Total(value0 Views) int64 {
	lock.Lock()
	defer lock.Unlock()
	var total int64
	for _, n := range replicas[value0.Id] {
		total += n
	}
	return total
}
