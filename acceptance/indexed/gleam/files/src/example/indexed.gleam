// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
import lawspec/data as d

pub fn replicate(n: Int, x: Int) -> d.Vec(Int) {
  case n { 0 -> d.VecVNil _ -> d.VecVCons(d.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec(x, replicate(n - 1, x))) }
}
pub fn append(xs: d.Vec(Int), ys: d.Vec(Int)) -> d.Vec(Int) {
  case xs { d.VecVNil -> ys d.VecVCons(d.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec(h, t)) -> d.VecVCons(d.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec(h, append(t, ys))) }
}
pub fn zip(xs: d.Vec(Int), ys: d.Vec(Bool)) -> d.Vec(Bool) {
  case xs, ys {
    d.VecVNil, d.VecVNil -> d.VecVNil
    d.VecVCons(d.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec(_, t)), d.VecVCons(d.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec(h, u)) -> d.VecVCons(d.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec(h, zip(t, u)))
    _, _ -> panic as "different lengths"
  }
}
pub fn flatten(tree: d.Tree(Int)) -> d.Vec(Int) {
  case tree {
    d.TreeTip -> d.VecVNil
    d.TreeBin(d.Recorde00f7d8e028cf6be6e08b4ed1f9853199bee01cf39e5a2faa3e38b8ad29bf271(l, r, v)) -> append(flatten(l), d.VecVCons(d.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec(v, flatten(r))))
  }
}
