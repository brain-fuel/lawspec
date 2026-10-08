// User-owned LawSpec adapter. Implement these functions.

import lawspec/abilities/example/abilities as abilities_example_abilities

import lawspec/abilities/example/shop as abilities_example_shop

pub fn refund(_handler0: abilities_example_abilities.Gateway, _argument0: Int) -> Int {
  panic as "Not implemented: example.shop::refund"
}

pub fn log_handler() -> abilities_example_shop.Log {
  abilities_example_shop.log(
    fn(_argument0) { panic as "Not implemented: example.shop::ability::Log.note" }
  )
}

pub fn store_int32_handler() -> abilities_example_shop.StoreInt32 {
  abilities_example_shop.store_int32(
    fn() { panic as "Not implemented: example.shop::ability::Store(Int32).load" },
    fn(_argument0) { panic as "Not implemented: example.shop::ability::Store(Int32).save" }
  )
}

pub fn store_text_handler() -> abilities_example_shop.StoreText {
  abilities_example_shop.store_text(
    fn() { panic as "Not implemented: example.shop::ability::Store(Text).load" },
    fn(_argument0) { panic as "Not implemented: example.shop::ability::Store(Text).save" }
  )
}

pub fn meter_handler() -> abilities_example_shop.Meter {
  abilities_example_shop.meter(
    fn() { panic as "Not implemented: example.shop::ability::Meter.reading" }
  )
}
