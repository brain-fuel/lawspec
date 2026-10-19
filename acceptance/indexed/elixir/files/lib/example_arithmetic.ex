# User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
defmodule Example.Arithmetic do
  alias LawSpec.Data, as: D

  def mirror(%D.PerfectLeaf{} = v), do: v
  def mirror(%D.PerfectNode{value: %D.Recordbf7449c93365b618bf1a5ee73f403facd0ee7b030d813d5e8c718611ac928ef8{left: l, right: r}}), do: %D.PerfectNode{value: %D.Recordbf7449c93365b618bf1a5ee73f403facd0ee7b030d813d5e8c718611ac928ef8{left: mirror(r), right: mirror(l)}}
  def area(%D.Grid{value: %D.Recordc0281b0d702b4d15fb4288afca7f776df7cdbc7cc164691755e2475920fa5bd9{rows: rows, columns: columns}}), do: count(rows) * count(columns)
  def duplicate(xs), do: %D.Halves{value: %D.Record90e2e86ad982c9c5e71a6cd286ab605cf2b3d771c37021fb930810c33933eb3d{front: xs, back: xs}}
  def count_pairs(xs), do: %D.Pairs{value: xs}
  def drop_first(xs), do: %D.Rest{value: xs}
  defp count(%D.RowEnd{}), do: 0
  defp count(%D.RowCell{value: %D.Record3b011c4276dbdecc2735ac0f8fa7ce5517233cc5b302ba305baeed3dec2f677f{tail: t}}), do: 1 + count(t)
end
