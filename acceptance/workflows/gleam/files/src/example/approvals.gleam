// ref:DEC-acceptance-with-mutants
import example/workflows/definitions
import gleam/list
import lawspec/data
import lawspec/workflow

@external(erlang, "beam_policy_probe", "monotonic_millis")
fn monotonic_millis() -> Int

pub fn approved_quickly(n: Int) -> Bool {
  use _ <- workflow.with_real(0)
  let started = monotonic_millis()
  let _ = definitions.approve(data.Order(n))
  monotonic_millis() - started < 550
}
pub fn approval_errors(n: Int) -> List(String) {
  use _ <- workflow.with_real(0)
  case definitions.approve(data.Order(n)) {
    Ok(_) -> []
    Error(data.ApproveErrorApproveFailures(errors)) -> list.map(errors, fn(error) {
      case error {
        data.ApproveErrorApproveCheckStockFailed(message) -> message
        data.ApproveErrorApproveCheckCreditFailed(message) -> message
        data.ApproveErrorApproveFailures(_) -> panic as "unexpected nested failure"
      }
    })
    Error(_) -> panic as "missing accumulated errors"
  }
}
