// User-owned LawSpec adapter. Implement these functions.

import lawspec/data

pub fn audit(_account_1: data.Account) -> Bool {
  panic as "Not implemented: example.workflows::audit"
}

pub fn waitlist(
  _signup_error_1: data.SignupError,
) -> Result(data.Account, data.SignupError) {
  panic as "Not implemented: example.workflows::waitlist"
}

pub fn check_stock(_order_1: data.Order) -> Result(data.Order, String) {
  panic as "Not implemented: example.workflows::checkStock"
}

pub fn check_credit(_order_1: data.Order) -> Result(data.Order, String) {
  panic as "Not implemented: example.workflows::checkCredit"
}

pub fn check_name(
  _signup_1: data.Signup,
) -> Result(data.Signup, data.SignupError) {
  panic as "Not implemented: example.workflows::checkName"
}

pub fn check_age(_signup_1: data.Signup) -> Result(data.Signup, String) {
  panic as "Not implemented: example.workflows::checkAge"
}

pub fn open_account(
  _signup_1: data.Signup,
) -> Result(data.Account, data.SignupError) {
  panic as "Not implemented: example.workflows::openAccount"
}
