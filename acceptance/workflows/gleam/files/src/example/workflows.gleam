// ref:DEC-acceptance-with-mutants
import lawspec/data

@external(erlang, "beam_policy_probe", "sleep_millis")
fn pause(milliseconds: Int) -> Nil

pub fn audit(_account: data.Account) -> Bool { True }
pub fn waitlist(error: data.SignupError) -> Result(data.Account, data.SignupError) {
  case error {
    data.SignupErrorUnavailable -> Ok(data.Account("waitlist", 18, 0))
    _ -> Error(error)
  }
}
pub fn check_name(signup: data.Signup) -> Result(data.Signup, data.SignupError) {
  case signup.name { "" -> Error(data.SignupErrorMissingName) _ -> Ok(signup) }
}
pub fn check_age(signup: data.Signup) -> Result(data.Signup, String) {
  case signup.age < 18 { True -> Error("too young") False -> Ok(signup) }
}
pub fn open_account(signup: data.Signup) -> Result(data.Account, data.SignupError) {
  case signup.name {
    "taken" -> Error(data.SignupErrorUnavailable)
    _ -> Ok(data.Account(signup.name, signup.age, 1))
  }
}
pub fn check_stock(order: data.Order) -> Result(data.Order, String) {
  case order.number { -1 -> pause(400) _ -> Nil }
  case order.number < 0 { True -> Error("no stock") False -> Ok(order) }
}
pub fn check_credit(order: data.Order) -> Result(data.Order, String) {
  case order.number { -1 -> pause(250) _ -> Nil }
  case order.number < 0 { True -> Error("no credit") False -> Ok(order) }
}
