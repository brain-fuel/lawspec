import lawspec/abilities/lawspec/time as clock
import lawspec/data
import lawspec/effects
import lawspec/time

pub type NativeClock {
  NativeClock(now: fn() -> data.Instant, sleep: fn(data.Duration) -> Nil)
}

pub fn steady_clock() -> NativeClock {
  let inner = time.clock_handler()
  let readings = effects.new_cell(0)
  NativeClock(
    fn() {
      let count = next_reading(readings)
      let _ = count
      let data.Instant(micros) = clock.clock_now(inner)
      data.Instant(micros)
    },
    fn(duration) { clock.clock_sleep(inner, duration) },
  )
}

@external(erlang, "builtins_ffi", "next_reading")
fn next_reading(cell: effects.Cell(Int)) -> Int
