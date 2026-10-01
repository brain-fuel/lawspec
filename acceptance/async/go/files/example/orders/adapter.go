// User-owned LawSpec adapter.
package orders

func price(sku string) int32 {
	if sku == "free" {
		return 0
	}
	return int32(len([]rune(sku)) % 100)
}

// Price looks the price up in a goroutine.
func Price(value0 string) LawSpecTask[int32] {
	return LawSpecGo(func() int32 { return price(value0) })
}

// Stock counts the stock in a goroutine.
func Stock(value0 string) LawSpecTask[int32] {
	return LawSpecGo(func() int32 { return int32(len([]rune(value0))) })
}

// Quote is the local price.
func Quote(value0 string) int32 {
	return price(value0)
}
