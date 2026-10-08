// Native factories allocate state owned by the current LawSpec scope.
import lawspec/abilities/example/abilities as payments
import lawspec/abilities/example/shop as shop
import lawspec/data
import lawspec/effects
import lawspec/failures

pub fn refund(gateway: payments.Gateway, cents: Int) -> Int {
  case cents > 100000 {
    True -> failures.fail(data.PaymentErrorTooLarge)
    False -> {
      let data.Receipt(paid) = payments.gateway_capture(gateway, cents)
      paid
    }
  }
}

pub fn log_handler() -> shop.Log {
  let lines = effects.new_cell([])
  shop.log(fn(text) { effects.write_cell(lines, [text, ..effects.read_cell(lines)]) })
}

pub fn store_int32_handler() -> shop.StoreInt32 {
  let stored = effects.new_cell(0)
  shop.store_int32(
    fn() { effects.read_cell(stored) },
    fn(value) { effects.write_cell(stored, value) },
  )
}

pub fn store_text_handler() -> shop.StoreText {
  let stored = effects.new_cell("")
  shop.store_text(
    fn() { effects.read_cell(stored) },
    fn(text) { effects.write_cell(stored, text) },
  )
}

pub fn meter_handler() -> shop.Meter {
  shop.meter(fn() { 3 })
}
