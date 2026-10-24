# User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
defmodule Example.Arithmetic do
  alias LawSpec.Data, as: D

  def mirror(%D.PerfectLeaf{} = v), do: v
  def mirror(%D.PerfectNode{value: %D.NodeDetails{left: l, right: r}}), do: %D.PerfectNode{value: %D.NodeDetails{left: mirror(r), right: mirror(l)}}
  def area(%D.Grid{value: %D.GridDetails{rows: rows, columns: columns}}), do: count(rows) * count(columns)
  def duplicate(xs), do: %D.Halves{value: %D.HalvesDetails{front: xs, back: xs}}
  def count_pairs(xs), do: %D.Pairs{value: xs}
  def drop_first(xs), do: %D.Rest{value: xs}
  defp count(%D.RowEnd{}), do: 0
  defp count(%D.RowCell{value: %D.CellDetails{tail: t}}), do: 1 + count(t)
end
