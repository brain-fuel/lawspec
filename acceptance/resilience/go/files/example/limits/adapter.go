// User-owned LawSpec adapter.
package limits

import (
	"sync/atomic"
	"time"
)

// AdmitTicket admits every ticket.
func AdmitTicket(value0 Ticket) LawSpecEither[string, Ticket] {
	return LawSpecRight[string, Ticket](value0)
}

// ReserveSeat reserves a seat.
func ReserveSeat(value0 Ticket) LawSpecEither[string, Ticket] {
	return LawSpecRight[string, Ticket](value0)
}

// ChargeCard declines a negative ticket.
func ChargeCard(value0 Ticket) LawSpecEither[string, Ticket] {
	if value0.Number < 0 {
		return LawSpecLeft[string, Ticket]("declined")
	}
	return LawSpecRight[string, Ticket](value0)
}

// ReleaseSeat releases a seat.
func ReleaseSeat(value0 Ticket) bool {
	return true
}

// FetchQuote quotes a ticket in a goroutine; ticket -1 takes 600ms.
func FetchQuote(value0 Ticket) LawSpecTask[LawSpecEither[string, Ticket]] {
	return LawSpecGo(func() LawSpecEither[string, Ticket] {
		if value0.Number == -1 {
			time.Sleep(600 * time.Millisecond)
		}
		return LawSpecRight[string, Ticket](value0)
	})
}

var quotes atomic.Int64

// ResetQuotes starts ticket -2's quotes again.
func ResetQuotes() { quotes.Store(0) }

// HedgeQuote stalls ticket -2's first quote (and every other one after).
func HedgeQuote(value0 Ticket) LawSpecTask[LawSpecEither[string, Ticket]] {
	stall := value0.Number == -2 && quotes.Add(1)%2 == 1
	return LawSpecGo(func() LawSpecEither[string, Ticket] {
		if stall {
			time.Sleep(600 * time.Millisecond)
		}
		return LawSpecRight[string, Ticket](value0)
	})
}
