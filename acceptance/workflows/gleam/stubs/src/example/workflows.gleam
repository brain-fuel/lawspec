// User-owned LawSpec adapter. Implement these functions.

import lawspec/data

pub fn audit(_argument0: data.Account) -> Bool {
  panic as "Not implemented: example.workflows::audit"
}

pub fn waitlist(_argument0: data.SignupError) -> Result(data.Account, data.SignupError) {
  panic as "Not implemented: example.workflows::waitlist"
}

pub fn check_stock(_argument0: data.Order) -> Result(data.Order, String) {
  panic as "Not implemented: example.workflows::checkStock"
}

pub fn check_credit(_argument0: data.Order) -> Result(data.Order, String) {
  panic as "Not implemented: example.workflows::checkCredit"
}

pub fn check_name(_argument0: data.Signup) -> Result(data.Signup, data.SignupError) {
  panic as "Not implemented: example.workflows::checkName"
}

pub fn check_age(_argument0: data.Signup) -> Result(data.Signup, String) {
  panic as "Not implemented: example.workflows::checkAge"
}

pub fn open_account(_argument0: data.Signup) -> Result(data.Account, data.SignupError) {
  panic as "Not implemented: example.workflows::openAccount"
}
