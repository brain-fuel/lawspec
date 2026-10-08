# User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
defmodule Example.Arithmetic do
  alias LawSpec.Data, as: D

  def mirror(%D.PerfectLeaf{} = v), do: v
  def mirror(%D.PerfectNode{left: l, right: r}), do: %D.PerfectNode{left: mirror(r), right: mirror(l)}
  def area(%D.Grid{rows: rows, columns: columns}), do: count(rows) * count(columns)
  def duplicate(xs), do: %D.Halves{front: xs, back: xs}
  def count_pairs(xs), do: %D.Pairs{items: xs}
  def drop_first(xs), do: %D.Rest{items: xs}
  defp count(%D.RowEnd{}), do: 0
  defp count(%D.RowCell{tail: t}), do: 1 + count(t)
end
