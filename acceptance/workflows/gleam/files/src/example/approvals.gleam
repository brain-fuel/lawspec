// ref:DEC-acceptance-with-mutants
import example/workflows/definitions
import gleam/list
import lawspec/data
import lawspec/workflow

@external(erlang, "beam_policy_probe", "since")
fn since() -> Int

@external(erlang, "beam_policy_probe", "overlapped")
fn overlapped(since: Int) -> Bool

// Whether two of order -1's slow checks that started during this call
// overlapped in time. Run one after the other they cannot overlap, however
// loaded the machine is. A fast order first loads the workflow's modules.
pub fn approved_quickly(n: Int) -> Bool {
  use _ <- workflow.with_real(0)
  let _ = definitions.approve(data.Order(0))
  let started = since()
  let _ = definitions.approve(data.Order(n))
  n != -1 || overlapped(started)
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
