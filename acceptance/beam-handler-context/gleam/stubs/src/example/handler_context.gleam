// User-owned LawSpec adapter. Implement these functions.

import lawspec/abilities/example/handler_context as abilities_example_handler_context

pub fn roundtrip(_handler0: abilities_example_handler_context.Counter, _argument0: Int) -> Int {
  panic as "Not implemented: example.handlerContext::roundtrip"
}

pub fn public_probe(_argument0: Nil) -> Bool {
  panic as "Not implemented: example.handlerContext::publicProbe"
}

pub fn counter_handler() -> abilities_example_handler_context.Counter {
  abilities_example_handler_context.counter(
    fn(_argument0) { panic as "Not implemented: example.handlerContext::ability::Counter.bump" },
    fn() { panic as "Not implemented: example.handlerContext::ability::Counter.current" }
  )
}

pub fn offset_handler() -> abilities_example_handler_context.Offset {
  abilities_example_handler_context.offset(
    fn() { panic as "Not implemented: example.handlerContext::ability::Offset.offset" }
  )
}
