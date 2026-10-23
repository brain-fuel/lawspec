// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
import lawspec/data as d

pub fn replicate(n: Int, x: Int) -> d.Vec(Int) {
  case n { 0 -> d.VecVNil _ -> d.VecVCons(d.VConsDetails(x, replicate(n - 1, x))) }
}
pub fn append(xs: d.Vec(Int), ys: d.Vec(Int)) -> d.Vec(Int) {
  case xs { d.VecVNil -> ys d.VecVCons(d.VConsDetails(h, t)) -> d.VecVCons(d.VConsDetails(h, append(t, ys))) }
}
pub fn zip(xs: d.Vec(Int), ys: d.Vec(Bool)) -> d.Vec(Bool) {
  case xs, ys {
    d.VecVNil, d.VecVNil -> d.VecVNil
    d.VecVCons(d.VConsDetails(_, t)), d.VecVCons(d.VConsDetails(h, u)) -> d.VecVCons(d.VConsDetails(h, zip(t, u)))
    _, _ -> panic as "different lengths"
  }
}
pub fn flatten(tree: d.Tree(Int)) -> d.Vec(Int) {
  case tree {
    d.TreeTip -> d.VecVNil
    d.TreeBin(d.BinDetails(l, r, v)) -> append(flatten(l), d.VecVCons(d.VConsDetails(v, flatten(r))))
  }
}
