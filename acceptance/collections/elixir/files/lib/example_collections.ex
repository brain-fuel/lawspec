# ref:DEC-acceptance-with-mutants
defmodule Example.Collections do
  alias LawSpec.Data, as: D
  def dedupe(values), do: %D.Set{items: Enum.sort(Enum.uniq(values))}
  def word_counts(words) do
    entries = words |> Enum.frequencies() |> Enum.sort() |> Enum.map(fn {word, count} -> %D.Entry{key: word, value: count} end)
    %D.KeyVal{entries: entries}
  end
  def fifo(values), do: %D.Queue{items: values}
  def lifo(values), do: %D.Stack{items: Enum.reverse(values)}
  def rotate(%D.Deque{items: []} = empty), do: empty
  def rotate(%D.Deque{items: [head | rest]}), do: %D.Deque{items: rest ++ [head]}
  def distinct_rows(rows), do: %D.Set{items: Enum.sort(Enum.uniq(rows))}
end
