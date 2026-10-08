// User-owned native functions and production ability interface.
import lawspec/abilities/example/abilities as abilities
import lawspec/data

pub fn charge(gateway: abilities.Gateway, cents: Int) -> Bool {
  case abilities.gateway_authorize(gateway, cents) {
    data.PaymentApproved(approved) -> {
      let data.Receipt(paid) = abilities.gateway_capture(gateway, approved)
      paid == cents
    }
    data.PaymentDeclined -> False
  }
}

pub fn gateway_handler() -> abilities.Gateway {
  abilities.gateway(
    fn(cents) {
      case cents < 0 {
        True -> data.PaymentDeclined
        False -> data.PaymentApproved(cents)
      }
    },
    fn(cents) { data.Receipt(cents) },
    fn() { 25 },
  )
}
