// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
import lawspec/data as d

pub fn mirror(tree: d.Perfect) -> d.Perfect {
  case tree {
    d.PerfectLeaf(_) -> tree
    d.PerfectNode(d.Recordbf7449c93365b618bf1a5ee73f403facd0ee7b030d813d5e8c718611ac928ef8(l, r)) -> d.PerfectNode(d.Recordbf7449c93365b618bf1a5ee73f403facd0ee7b030d813d5e8c718611ac928ef8(mirror(r), mirror(l)))
  }
}
pub fn area(grid: d.Grid) -> Int { count(grid.value.rows) * count(grid.value.columns) }
pub fn duplicate(xs: d.Row) -> d.Halves { d.Halves(d.Record90e2e86ad982c9c5e71a6cd286ab605cf2b3d771c37021fb930810c33933eb3d(xs, xs)) }
pub fn count_pairs(xs: d.Row) -> d.Pairs { d.Pairs(xs) }
pub fn drop_first(xs: d.Row) -> d.Rest { d.Rest(xs) }
fn count(row: d.Row) -> Int {
  case row { d.RowEnd -> 0 d.RowCell(d.Record3b011c4276dbdecc2735ac0f8fa7ce5517233cc5b302ba305baeed3dec2f677f(_, t)) -> 1 + count(t) }
}
