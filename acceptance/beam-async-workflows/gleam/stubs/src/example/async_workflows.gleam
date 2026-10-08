// User-owned LawSpec adapter. Implement these functions.

import lawspec/abilities/example/async_workflows as abilities_example_async_workflows

pub fn first(
  _handler0: abilities_example_async_workflows.Coordination,
  _argument0: Int
) -> Result(Int, String) {
  panic as "Not implemented: example.asyncWorkflows::first"
}

pub fn second(
  _handler0: abilities_example_async_workflows.Coordination,
  _argument0: Int
) -> Result(Int, String) {
  panic as "Not implemented: example.asyncWorkflows::second"
}

pub fn public_probe(_argument0: Nil) -> Bool {
  panic as "Not implemented: example.asyncWorkflows::publicProbe"
}

pub fn coordination_handler() -> abilities_example_async_workflows.Coordination {
  abilities_example_async_workflows.coordination(
    fn(
      _argument0
    ) { panic as "Not implemented: example.asyncWorkflows::ability::Coordination.meet" },
    fn(
      _argument0
    ) { panic as "Not implemented: example.asyncWorkflows::ability::Coordination.finish" }
  )
}
