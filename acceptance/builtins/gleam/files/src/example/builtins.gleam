import lawspec/abilities/lawspec/time as clock
import lawspec/abilities/lawspec/randomness
import lawspec/abilities/lawspec/host
import lawspec/abilities/lawspec/logging
import lawspec/data

pub fn elapsed(handler: clock.Clock, count: Int) -> data.Duration {
  let data.Instant(start) = clock.clock_now(handler)
  readings(handler, count)
  let data.Instant(finish) = clock.clock_now(handler)
  data.Duration(finish - start)
}

fn readings(handler: clock.Clock, count: Int) -> Nil {
  case count > 0 {
    True -> {
      let _ = clock.clock_now(handler)
      readings(handler, count - 1)
    }
    False -> Nil
  }
}

pub fn token(handler: randomness.SecureRandom, count: Int) -> BitArray {
  randomness.secure_random_secure_bytes(handler, count)
}

pub fn listening(handler: host.Ports, _count: Int) -> Bool {
  listen_on(host.ports_free_port(handler))
}

@external(erlang, "builtins_ffi", "listen_on")
fn listen_on(port: Int) -> Bool

pub fn charge(handler: logging.Log, cents: Int) -> Bool {
  case cents % 2 == 0 {
    True -> {
      logging.log_log_message(handler, data.LogLevelInfo, "charged")
      True
    }
    False -> False
  }
}
