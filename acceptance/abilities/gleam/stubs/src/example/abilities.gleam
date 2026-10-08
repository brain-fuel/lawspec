// User-owned LawSpec adapter. Implement these functions.

import lawspec/abilities/example/abilities as abilities_example_abilities

pub fn charge(_handler0: abilities_example_abilities.Gateway, _argument0: Int) -> Bool {
  panic as "Not implemented: example.abilities::charge"
}

pub fn gateway_handler() -> abilities_example_abilities.Gateway {
  abilities_example_abilities.gateway(
    fn(_argument0) { panic as "Not implemented: example.abilities::ability::Gateway.authorize" },
    fn(_argument0) { panic as "Not implemented: example.abilities::ability::Gateway.capture" },
    fn() { panic as "Not implemented: example.abilities::ability::Gateway.fee" }
  )
}
