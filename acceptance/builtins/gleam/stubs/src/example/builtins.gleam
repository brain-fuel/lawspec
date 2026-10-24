// User-owned LawSpec adapter. Implement these functions.

import lawspec/abilities/lawspec/host as abilities_lawspec_host
import lawspec/abilities/lawspec/logging as abilities_lawspec_logging
import lawspec/abilities/lawspec/randomness as abilities_lawspec_randomness
import lawspec/abilities/lawspec/time as abilities_lawspec_time
import lawspec/data

pub fn elapsed(
  _clock_handler: abilities_lawspec_time.Clock,
  _int32: Int,
) -> data.Duration {
  panic as "Not implemented: example.builtins::elapsed"
}

pub fn token(
  _secure_random_handler: abilities_lawspec_randomness.SecureRandom,
  _int32: Int,
) -> BitArray {
  panic as "Not implemented: example.builtins::token"
}

pub fn listening(
  _ports_handler: abilities_lawspec_host.Ports,
  _int32: Int,
) -> Bool {
  panic as "Not implemented: example.builtins::listening"
}

pub fn charge(
  _log_handler: abilities_lawspec_logging.Log,
  _int32: Int,
) -> Bool {
  panic as "Not implemented: example.builtins::charge"
}
