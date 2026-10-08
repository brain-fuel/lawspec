// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
import lawspec/data as d

pub fn eval_number(expr: d.Expr(Int)) -> Int { number(expr) }
fn number(expr: d.Expr(a)) -> Int {
  case expr {
    d.ExprNumber(v) -> v
    d.ExprPlus(l, r) -> eval_number(l) + eval_number(r)
    _ -> panic as "not an Expr BigInt"
  }
}
pub fn eval_truth(expr: d.Expr(Bool)) -> Bool { truth(expr) }
fn truth(expr: d.Expr(a)) -> Bool {
  case expr {
    d.ExprTruth(b) -> b
    d.ExprSame(l, r) -> number(l) == number(r)
    d.ExprNegate(x) -> !eval_truth(x)
    _ -> panic as "not an Expr Bool"
  }
}
pub fn eval_pair(expr: d.Expr(d.Pair(Int, Bool))) -> d.Pair(Int, Bool) {
  case expr {
    d.ExprBoth(l, r) -> d.Pair(number(l), truth(r))
    _ -> panic as "not an Expr Pair"
  }
}
pub fn fold(expr: d.Expr(Int)) -> d.Expr(Int) { d.ExprNumber(number(expr)) }
pub fn describe(value: d.Shown) -> String { value.lawspec_type_0 }
