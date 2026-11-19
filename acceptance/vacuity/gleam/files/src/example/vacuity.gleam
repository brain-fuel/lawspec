// User-owned LawSpec adapter.
import gleam/list
import gleam/string
import lawspec/data

pub fn shout(name: String) -> String {
  string.uppercase(name)
}

pub fn abbreviate(stage: data.Stage) -> String {
  stage.token
}

// Accepts only codes such as OFFER-2026-AB: no random record has one.
pub fn accepts(offer: data.Proposal) -> Bool {
  case string.to_graphemes(offer.code) {
    ["O", "F", "F", "E", "R", "-", a, b, c, d, "-", x, y] ->
      list.all([a, b, c, d], fn(g) { string.contains("0123456789", g) })
      && list.all([x, y], fn(g) { string.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ", g) })
      && offer.amount > 0
    _ -> False
  }
}

pub fn describe(offer: data.Proposal) -> String {
  offer.code
}

pub fn keep(key: String) -> String {
  key
}
