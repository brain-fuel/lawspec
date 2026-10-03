// User-owned LawSpec adapter.
package limits

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
