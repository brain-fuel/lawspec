// User-owned LawSpec adapter: a stack and an atomic counter.
package models

import "sync"

var (
	counters = map[int32]int64{}
	ids      int32
	lock     sync.Mutex
)

// Empty makes an empty stack.
func Empty(value0 LawSpecValue) Stack {
	return StackEmpty{}
}

// Push puts a value on top of the stack.
func Push(value0 int8, value1 Stack) PushFlow {
	return PushFlow{State: StackPush{Top: value0, Rest: value1}}
}

// Pop takes the top value; the flow signature guarantees one.
func Pop(value0 Stack) PopFlow {
	cell := value0.(StackPush)
	return PopFlow{Result: cell.Top, State: cell.Rest}
}

// Peek reads the top value and keeps the stack.
func Peek(value0 Stack) PeekFlow {
	cell := value0.(StackPush)
	return PeekFlow{Result: cell.Top, State: cell}
}

// NewCounter makes a counter at zero.
func NewCounter(value0 LawSpecValue) Counter {
	lock.Lock()
	defer lock.Unlock()
	ids++
	counters[ids] = 0
	return Counter{Id: ids}
}

// Increment adds one, atomically, in a goroutine.
func Increment(value0 Counter) LawSpecTask[int64] {
	return LawSpecGo(func() int64 {
		lock.Lock()
		defer lock.Unlock()
		counters[value0.Id]++
		return counters[value0.Id]
	})
}

// Decrement subtracts one, atomically, in a goroutine.
func Decrement(value0 Counter) LawSpecTask[int64] {
	return LawSpecGo(func() int64 {
		lock.Lock()
		defer lock.Unlock()
		counters[value0.Id]--
		return counters[value0.Id]
	})
}

// Read reads the count in a goroutine.
func Read(value0 Counter) LawSpecTask[int64] {
	return LawSpecGo(func() int64 {
		lock.Lock()
		defer lock.Unlock()
		return counters[value0.Id]
	})
}
