// User-owned LawSpec adapter. Implement these functions.

import lawspec/data

pub fn eval_number(_argument0: data.Expr(Int)) -> Int {
  panic as "Not implemented: example.gadt::evalNumber"
}

pub fn eval_truth(_argument0: data.Expr(Bool)) -> Bool {
  panic as "Not implemented: example.gadt::evalTruth"
}

pub fn eval_pair(_argument0: data.Expr(data.Pair(Int, Bool))) -> data.Pair(Int, Bool) {
  panic as "Not implemented: example.gadt::evalPair"
}

pub fn fold(_argument0: data.Expr(Int)) -> data.Expr(Int) {
  panic as "Not implemented: example.gadt::fold"
}

pub fn describe(_argument0: data.Shown) -> String {
  panic as "Not implemented: example.gadt::describe"
}
