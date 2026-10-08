import example/handler_context/definitions
import lawspec/abilities/example/handler_context as abilities
import lawspec/effects

pub fn roundtrip(counter: abilities.Counter, amount: Int) -> Int {
  definitions.shifted(counter, amount)
}

pub fn async_roundtrip(counter: abilities.Counter, amount: Int) -> Int {
  let scratch = effects.new_cell(amount)
  definitions.shifted(counter, effects.read_cell(scratch))
}

pub fn public_probe(_unit: Nil) -> Bool {
  effects.with_context(fn(context) {
    let counter = abilities.fresh_counter(context)
    let recorded = abilities.recording_counter(context, counter)
    definitions.advance(recorded, 2) == 2 && definitions.shifted(recorded, 3) == 105
  })
}

pub fn counter_handler() -> abilities.Counter {
  let total = effects.new_cell(0)
  abilities.counter(
    fn(amount) {
      let value = effects.read_cell(total) + amount
      effects.write_cell(total, value)
      value
    },
    fn() { effects.read_cell(total) },
  )
}

pub fn offset_handler() -> abilities.Offset {
  abilities.offset(fn() { 0 })
}
