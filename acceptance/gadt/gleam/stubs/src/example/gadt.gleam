// User-owned LawSpec adapter. Implement these functions.

import lawspec/data

pub fn eval_number(_expr_integer: data.Expr(Int)) -> Int {
  panic as "Not implemented: example.gadt::evalNumber"
}

pub fn eval_truth(_expr_bool: data.Expr(Bool)) -> Bool {
  panic as "Not implemented: example.gadt::evalTruth"
}

pub fn eval_pair(
  _expr_pair_integer_bool: data.Expr(data.Pair(Int, Bool)),
) -> data.Pair(Int, Bool) {
  panic as "Not implemented: example.gadt::evalPair"
}

pub fn fold(_expr_integer: data.Expr(Int)) -> data.Expr(Int) {
  panic as "Not implemented: example.gadt::fold"
}

pub fn describe(_shown: data.Shown) -> String {
  panic as "Not implemented: example.gadt::describe"
}
