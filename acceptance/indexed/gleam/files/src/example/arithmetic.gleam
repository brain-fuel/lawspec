// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
import lawspec/data as d

pub fn mirror(tree: d.Perfect) -> d.Perfect {
  case tree {
    d.PerfectLeaf(_) -> tree
    d.PerfectNode(d.NodeDetails(l, r)) -> d.PerfectNode(d.NodeDetails(mirror(r), mirror(l)))
  }
}
pub fn area(grid: d.Grid) -> Int { count(grid.value.rows) * count(grid.value.columns) }
pub fn duplicate(xs: d.Row) -> d.Halves { d.Halves(d.HalvesDetails(xs, xs)) }
pub fn count_pairs(xs: d.Row) -> d.Pairs { d.Pairs(xs) }
pub fn drop_first(xs: d.Row) -> d.Rest { d.Rest(xs) }
fn count(row: d.Row) -> Int {
  case row { d.RowEnd -> 0 d.RowCell(d.CellDetails(_, t)) -> 1 + count(t) }
}
