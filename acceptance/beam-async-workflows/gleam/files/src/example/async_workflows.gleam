// ref:DEC-acceptance-with-mutants
import example/async_workflows/definitions
import lawspec/abilities/example/async_workflows as abilities
import lawspec/data

pub fn first(coordination: abilities.Coordination, n: Int) -> Result(Int, String) {
  abilities.coordination_meet(coordination, 1)
  abilities.coordination_finish(coordination, 1)
  case n < 0 { True -> Error("first") False -> Ok(n) }
}
pub fn second(coordination: abilities.Coordination, n: Int) -> Result(Int, String) {
  abilities.coordination_meet(coordination, 2)
  abilities.coordination_finish(coordination, 2)
  case n < 0 { True -> Error("second") False -> Ok(n) }
}
pub fn coordination_handler() -> abilities.Coordination {
  abilities.coordination(fn(_) { Nil }, fn(_) { Nil })
}
@external(erlang, "beam_async_probe", "probe")
fn probe(body: fn(fn(Int) -> Nil, fn(Int) -> Nil) -> Bool, unit: Nil) -> Bool
pub fn public_probe(_unit: Nil) -> Bool {
  probe(fn(meet, finish) {
    definitions.both(abilities.coordination(meet, finish), -1) ==
      Error(data.BothErrorBothFailures([
        data.BothErrorBothFirstFailed("first"), data.BothErrorBothSecondFailed("second")]))
  }, Nil) && probe(fn(meet, finish) {
    definitions.first_failure(abilities.coordination(meet, finish), -1) ==
      Error(data.FirstFailureErrorFirstFailureFirstFailed("first"))
  }, Nil)
}
