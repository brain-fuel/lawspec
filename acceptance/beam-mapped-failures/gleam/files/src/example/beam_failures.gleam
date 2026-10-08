// ref:DEC-acceptance-with-mutants
import example/beam_failures/definitions
import lawspec/failures.{fail}
import lawspec/data


pub fn refund(n: Int) -> Int {
  case n {
    n if n < 0 -> declined("negative refund")
    n if n > 5000 -> fail(data.RejectionLimit(5000))
    _ -> n
  }
}

pub fn checked_limit(n: Int) -> Int {
  case n {
    n if n < 0 -> blocked()
    _ -> definitions.limit(n)
  }
}

@external(erlang, "beam_failures_exceptions", "declined")
fn declined(message: String) -> Int

@external(erlang, "beam_failures_exceptions", "blocked")
fn blocked() -> Int
