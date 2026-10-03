// User-owned LawSpec adapter.
package limits

// AdmitTicket admits every ticket.
func AdmitTicket(value0 Ticket) LawSpecEither[string, Ticket] {
	return LawSpecRight[string, Ticket](value0)
}
