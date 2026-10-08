// ref:DEC-acceptance-with-mutants
import lawspec/data

@external(erlang, "beam_policy_probe", "sleep_millis")
fn pause(milliseconds: Int) -> Nil
@external(erlang, "beam_policy_probe", "quote_count")
fn quote_count() -> Int

pub fn admit_ticket(ticket: data.Ticket) -> Result(data.Ticket, String) { Ok(ticket) }
pub fn reserve_seat(ticket: data.Ticket) -> Result(data.Ticket, String) { Ok(ticket) }
pub fn charge_card(ticket: data.Ticket) -> Result(data.Ticket, String) {
  case ticket.number < 0 { True -> Error("declined") False -> Ok(ticket) }
}
pub fn release_seat(_ticket: data.Ticket) -> Bool { True }
pub fn fetch_quote(ticket: data.Ticket) -> Result(data.Ticket, String) {
  case ticket.number { -1 -> pause(600) _ -> Nil }
  Ok(ticket)
}
pub fn hedge_quote(ticket: data.Ticket) -> Result(data.Ticket, String) {
  case ticket.number == -2 && quote_count() % 2 == 1 { True -> pause(600) False -> Nil }
  Ok(ticket)
}
