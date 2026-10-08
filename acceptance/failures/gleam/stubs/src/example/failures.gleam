// User-owned LawSpec adapter. Implement these functions.

import lawspec/abilities/example/failures as abilities_example_failures

pub fn refund(_argument0: Int) -> Int { panic as "Not implemented: example.failures::refund" }

pub fn settle(_argument0: Int) -> Int { panic as "Not implemented: example.failures::settle" }

pub fn gateway_handler() -> abilities_example_failures.Gateway {
  abilities_example_failures.gateway(
    fn(_argument0) { panic as "Not implemented: example.failures::ability::Gateway.decide" }
  )
}
