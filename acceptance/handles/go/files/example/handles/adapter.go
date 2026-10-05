// User-owned LawSpec adapter.
package handles

import "sync"

// jobs is the handle's native value: a mutex-guarded FIFO queue.
type jobs struct {
	lock  sync.Mutex
	items []int32
}

// NewJobs implements newJobs :: (Unit -> example.handles::type::Jobs).
func NewJobs(value0 LawSpecValue) any {
	return &jobs{}
}

// Submit implements submit :: (example.handles::type::Jobs -> (Int32 -> Unit)).
func Submit(value0 any, value1 int32) {
	queue := value0.(*jobs)
	queue.lock.Lock()
	defer queue.lock.Unlock()
	queue.items = append(queue.items, value1)
}

// Take implements take :: (example.handles::type::Jobs -> Maybe (Int32)).
func Take(value0 any) LawSpecMaybe[int32] {
	queue := value0.(*jobs)
	queue.lock.Lock()
	defer queue.lock.Unlock()
	if len(queue.items) == 0 {
		return LawSpecNothing[int32]()
	}
	front := queue.items[0]
	queue.items = queue.items[1:]
	return LawSpecJust(front)
}

// Pending implements pending :: (example.handles::type::Jobs -> Int32).
func Pending(value0 any) int32 {
	queue := value0.(*jobs)
	queue.lock.Lock()
	defer queue.lock.Unlock()
	return int32(len(queue.items))
}
