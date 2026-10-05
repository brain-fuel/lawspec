// Application code the warehouse adapters are bound to: some of it
// asynchronous, as a real service client would be.
package warehouse

import "sync"

func price(sku string) int32 {
	if sku == "free" {
		return 0
	}
	return int32(len([]rune(sku)) % 100)
}

// PriceOf looks the price up in a goroutine.
func PriceOf(sku string) LawSpecTask[int32] {
	return LawSpecGo(func() int32 { return price(sku) })
}

// QuoteOf is the local price.
func QuoteOf(sku string) int32 {
	return price(sku)
}

// Shelf is a stock count that several callers may change.
type Shelf struct {
	lock  sync.Mutex
	total int64
}

// NewShelf makes an empty shelf.
func NewShelf() *Shelf {
	return &Shelf{}
}

// Restock adds to the count in a goroutine.
func (s *Shelf) Restock(amount int32) LawSpecTask[LawSpecUnit] {
	return LawSpecGo(func() LawSpecUnit {
		s.lock.Lock()
		defer s.lock.Unlock()
		s.total += int64(amount)
		return LawSpecUnit{}
	})
}

// Count reads the count in a goroutine.
func (s *Shelf) Count() LawSpecTask[int64] {
	return LawSpecGo(func() int64 {
		s.lock.Lock()
		defer s.lock.Unlock()
		return s.total
	})
}
