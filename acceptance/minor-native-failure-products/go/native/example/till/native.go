// Application code the till's bindings name: its own money type, a till
// that is the production handler, and payments that panic with its own
// errors.
package till

// Cash is the application's money.
type Cash struct {
	Cents int64
}

// CardDeclined is the application's error for a declined card.
type CardDeclined struct{}

func (CardDeclined) Error() string { return "declined" }

// BadAmount is the application's error for an amount it cannot take.
type BadAmount struct{ Reason string }

func (e BadAmount) Error() string { return e.Reason }

// NativeTill keeps what it takes.
type NativeTill struct{ taken int64 }

// NewNativeTill makes an empty till.
func NewNativeTill() *NativeTill { return &NativeTill{} }

func (till *NativeTill) Take(money Cash) Cash {
	till.taken += money.Cents
	return Cash{Cents: money.Cents}
}

func (till *NativeTill) Opening() Cash { return Cash{} }

// Pay is a bound adapter. It gets its drawer as the generated interface.
func Pay(drawer Drawer, cents int64) Cash {
	if cents < 0 {
		panic(BadAmount{Reason: "negative"})
	}
	if cents > 1000 {
		panic(CardDeclined{})
	}
	return Cash{Cents: drawer.Take(Money{Cents: cents}).Cents}
}
