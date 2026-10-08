// User-owned LawSpec adapter. Implement these functions.

import lawspec/abilities/lawspec/time as abilities_lawspec_time

import lawspec/abilities/lawspec/randomness as abilities_lawspec_randomness

import lawspec/abilities/lawspec/host as abilities_lawspec_host

import lawspec/abilities/lawspec/logging as abilities_lawspec_logging

import lawspec/data

pub fn elapsed(_handler0: abilities_lawspec_time.Clock, _argument0: Int) -> data.Duration {
  panic as "Not implemented: example.builtins::elapsed"
}

pub fn token(_handler0: abilities_lawspec_randomness.SecureRandom, _argument0: Int) -> BitArray {
  panic as "Not implemented: example.builtins::token"
}

pub fn listening(_handler0: abilities_lawspec_host.Ports, _argument0: Int) -> Bool {
  panic as "Not implemented: example.builtins::listening"
}

pub fn charge(_handler0: abilities_lawspec_logging.Log, _argument0: Int) -> Bool {
  panic as "Not implemented: example.builtins::charge"
}
