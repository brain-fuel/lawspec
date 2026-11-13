// User-owned LawSpec adapter. Implement these functions.

import lawspec/data

pub fn eval_number(_expr_1: data.Expr(Int)) -> Int {
  panic as "Not implemented: example.gadt::evalNumber"
}

pub fn eval_truth(_expr_1: data.Expr(Bool)) -> Bool {
  panic as "Not implemented: example.gadt::evalTruth"
}

pub fn eval_pair(
  _expr_1: data.Expr(data.Pair(Int, Bool)),
) -> data.Pair(Int, Bool) {
  panic as "Not implemented: example.gadt::evalPair"
}

pub fn fold(_expr_1: data.Expr(Int)) -> data.Expr(Int) {
  panic as "Not implemented: example.gadt::fold"
}

pub fn describe(_shown_1: data.Shown) -> String {
  panic as "Not implemented: example.gadt::describe"
}
