// User-owned LawSpec adapter.
import LawSpecRuntime

extension Example.Vacuity {
  /// shout :: Text -> Text — vacuity.lawspec:26
  static func shout(_ name: String) -> String {
    name.uppercased()
  }

  /// abbreviate :: example.vacuity::type::Stage -> Text — vacuity.lawspec:27
  static func abbreviate(_ stage: Stage) -> String {
    stage.token
  }

  /// accepts :: example.vacuity::type::Proposal -> Bool — vacuity.lawspec:28
  /// Accepts only codes such as OFFER-2026-AB: no random record has one.
  static func accepts(_ offer: Proposal) -> Bool {
    let code = Array(offer.code.unicodeScalars)
    guard code.count == 13, String(String.UnicodeScalarView(code[0..<6])) == "OFFER-", code[10] == "-"
    else {
      return false
    }
    let digits = code[6..<10].allSatisfy { ("0"..."9").contains($0) }
    let letters = code[11..<13].allSatisfy { ("A"..."Z").contains($0) }
    return digits && letters && offer.amount > 0
  }

  /// describe :: example.vacuity::type::Proposal -> Text — vacuity.lawspec:29
  static func describe(_ offer: Proposal) -> String {
    offer.code
  }

  /// keep :: Text -> Text — vacuity.lawspec:30
  static func keep(_ key: String) -> String {
    key
  }
}
