// User-owned LawSpec adapter: a queue, a set and a map shared between
// goroutines, each guarded by its own lock.
package concurrent

import (
	"sync"
	"sync/atomic"
)

type workQueue struct {
	lock  sync.Mutex
	items []int32
}

type tagSet struct {
	lock  sync.Mutex
	items map[int32]bool
}

type cacheMap struct {
	lock    sync.Mutex
	entries map[int8]int64
}

// One registry per kind, from handle id to structure.
var (
	queues, tagSets, caches sync.Map
	nextId                  atomic.Int32
)

// newHandle registers a fresh structure under a new handle id.
func newHandle(registry *sync.Map, value any) int32 {
	id := nextId.Add(1) - 1
	registry.Store(id, value)
	return id
}

// handle is a structure by its handle; generated tests may name one first,
// so an unknown id gets an empty structure.
func handle[T any](registry *sync.Map, id int32, empty func() *T) *T {
	if found, ok := registry.Load(id); ok {
		return found.(*T)
	}
	found, _ := registry.LoadOrStore(id, empty())
	return found.(*T)
}

func queueOf(id int32) *workQueue {
	return handle(&queues, id, func() *workQueue { return &workQueue{} })
}

func tagsOf(id int32) *tagSet {
	return handle(&tagSets, id, func() *tagSet { return &tagSet{items: map[int32]bool{}} })
}

func cacheOf(id int32) *cacheMap {
	return handle(&caches, id, func() *cacheMap { return &cacheMap{entries: map[int8]int64{}} })
}

// NewQueue makes an empty queue.
func NewQueue(value0 LawSpecValue) WorkQueue {
	return WorkQueue{Id: newHandle(&queues, &workQueue{})}
}

// Offer puts a value at the back of the queue.
func Offer(value0 WorkQueue, value1 int32) LawSpecTask[LawSpecUnit] {
	return LawSpecGo(func() LawSpecUnit {
		q := queueOf(value0.Id)
		q.lock.Lock()
		defer q.lock.Unlock()
		q.items = append(q.items, value1)
		return LawSpecUnit{}
	})
}

// Poll takes the value at the front of the queue, if any.
func Poll(value0 WorkQueue) LawSpecTask[LawSpecMaybe[int32]] {
	return LawSpecGo(func() LawSpecMaybe[int32] {
		q := queueOf(value0.Id)
		q.lock.Lock()
		defer q.lock.Unlock()
		if len(q.items) == 0 {
			return LawSpecNothing[int32]()
		}
		front := q.items[0]
		q.items = q.items[1:]
		return LawSpecJust(front)
	})
}

// QueueSize counts the values in the queue.
func QueueSize(value0 WorkQueue) LawSpecTask[int64] {
	return LawSpecGo(func() int64 {
		q := queueOf(value0.Id)
		q.lock.Lock()
		defer q.lock.Unlock()
		return int64(len(q.items))
	})
}

// NewTags makes an empty set of tags.
func NewTags(value0 LawSpecValue) Tags {
	return Tags{Id: newHandle(&tagSets, &tagSet{items: map[int32]bool{}})}
}

// Tag adds a tag; true when it was not there.
func Tag(value0 Tags, value1 int32) LawSpecTask[bool] {
	return LawSpecGo(func() bool {
		s := tagsOf(value0.Id)
		s.lock.Lock()
		defer s.lock.Unlock()
		added := !s.items[value1]
		s.items[value1] = true
		return added
	})
}

// Untag removes a tag; true when it was there.
func Untag(value0 Tags, value1 int32) LawSpecTask[bool] {
	return LawSpecGo(func() bool {
		s := tagsOf(value0.Id)
		s.lock.Lock()
		defer s.lock.Unlock()
		present := s.items[value1]
		delete(s.items, value1)
		return present
	})
}

// Tagged is whether a tag is there.
func Tagged(value0 Tags, value1 int32) LawSpecTask[bool] {
	return LawSpecGo(func() bool {
		s := tagsOf(value0.Id)
		s.lock.Lock()
		defer s.lock.Unlock()
		return s.items[value1]
	})
}

// NewCache makes an empty cache.
func NewCache(value0 LawSpecValue) Cache {
	return Cache{Id: newHandle(&caches, &cacheMap{entries: map[int8]int64{}})}
}

func optional(value int64, present bool) LawSpecMaybe[int64] {
	if !present {
		return LawSpecNothing[int64]()
	}
	return LawSpecJust(value)
}

// Store sets a key's value and returns the previous one, if any.
func Store(value0 Cache, value1 int8, value2 int64) LawSpecTask[LawSpecMaybe[int64]] {
	return LawSpecGo(func() LawSpecMaybe[int64] {
		c := cacheOf(value0.Id)
		c.lock.Lock()
		defer c.lock.Unlock()
		previous, present := c.entries[value1]
		c.entries[value1] = value2
		return optional(previous, present)
	})
}

// Fetch reads a key's value, if any.
func Fetch(value0 Cache, value1 int8) LawSpecTask[LawSpecMaybe[int64]] {
	return LawSpecGo(func() LawSpecMaybe[int64] {
		c := cacheOf(value0.Id)
		c.lock.Lock()
		defer c.lock.Unlock()
		value, present := c.entries[value1]
		return optional(value, present)
	})
}

// Evict removes a key and returns its value, if any.
func Evict(value0 Cache, value1 int8) LawSpecTask[LawSpecMaybe[int64]] {
	return LawSpecGo(func() LawSpecMaybe[int64] {
		c := cacheOf(value0.Id)
		c.lock.Lock()
		defer c.lock.Unlock()
		value, present := c.entries[value1]
		delete(c.entries, value1)
		return optional(value, present)
	})
}
