// User-owned LawSpec adapter.
package harness

// Discount implements discount :: (example.harness::type::Order -> Int32).
func Discount(value0 Order) int32 {
	// Ten percent off orders of more than ten items.
	if value0.Items > 10 {
		return value0.Total / 10
	}
	return 0
}

// RoundCents implements roundCents :: (Int32 -> Int32).
func RoundCents(value0 int32) int32 {
	// To the nearest ten cents, halves down: known to break a law.
	return (value0 + 4) / 10 * 10
}

// Book implements book :: (Int32 -> Bool).
func Book(ledger Ledger, value0 int32) bool {
	return ledger.Accept(value0)
}

// LedgerHandler is the native handler of Ledger: accept.
type LedgerHandler struct{}

// NewLedgerHandler makes the native handler the generated tests use.
func NewLedgerHandler() Ledger {
	return &LedgerHandler{}
}

func (handler *LedgerHandler) Accept(value0 int32) bool {
	return value0 > 0
}
