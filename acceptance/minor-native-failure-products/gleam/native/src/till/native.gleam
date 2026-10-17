// The application types differ from the generated adapter's Drawer interface.
import lawspec/abilities/example/till as abilities
import lawspec/data
import lawspec/effects

pub type Cash {
  Cash(cash_cents: Int)
}

pub type NativeTill {
  NativeTill(take: fn(Cash) -> Cash, opening: fn() -> Cash)
}

pub fn new_native_till() -> NativeTill {
  let taken = effects.new_cell(0)
  NativeTill(
    take: fn(money) {
      effects.write_cell(taken, effects.read_cell(taken) + money.cash_cents)
      Cash(money.cash_cents)
    },
    opening: fn() { Cash(0) },
  )
}

pub fn pay(drawer: abilities.Drawer, cents: Int) -> Cash {
  case cents < 0, cents > 1000 {
    True, _ -> bad_amount("negative")
    _, True -> declined()
    _, _ -> {
      let data.Money(paid) = abilities.drawer_take(drawer, data.Money(cents))
      Cash(paid)
    }
  }
}

@external(erlang, "till_native_errors", "declined")
fn declined() -> a

@external(erlang, "till_native_errors", "bad_amount")
fn bad_amount(message: String) -> a
