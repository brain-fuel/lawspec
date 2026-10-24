// User-owned LawSpec adapter. Implement these functions.

import lawspec/data

pub fn admit_ticket(_ticket: data.Ticket) -> Result(data.Ticket, String) {
  panic as "Not implemented: example.limits::admitTicket"
}

pub fn reserve_seat(_ticket: data.Ticket) -> Result(data.Ticket, String) {
  panic as "Not implemented: example.limits::reserveSeat"
}

pub fn charge_card(_ticket: data.Ticket) -> Result(data.Ticket, String) {
  panic as "Not implemented: example.limits::chargeCard"
}

pub fn release_seat(_ticket: data.Ticket) -> Bool {
  panic as "Not implemented: example.limits::releaseSeat"
}

pub fn fetch_quote(_ticket: data.Ticket) -> Result(data.Ticket, String) {
  panic as "Not implemented: example.limits::fetchQuote"
}

pub fn hedge_quote(_ticket: data.Ticket) -> Result(data.Ticket, String) {
  panic as "Not implemented: example.limits::hedgeQuote"
}
