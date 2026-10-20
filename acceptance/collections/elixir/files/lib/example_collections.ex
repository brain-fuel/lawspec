# ref:DEC-acceptance-with-mutants
defmodule Example.Collections do
  alias LawSpec.Data, as: D
  def dedupe(values), do: %D.SortedSet{value: Enum.sort(Enum.uniq(values))}
  def word_counts(words) do
    entries = words |> Enum.frequencies() |> Enum.sort() |> Enum.map(fn {word, count} -> %D.Entry{key: word, value: count} end)
    %D.KeyVal{value: entries}
  end
  def fifo(values), do: %D.Queue{value: values}
  def lifo(values), do: %D.Stack{value: Enum.reverse(values)}
  def rotate(%D.Deque{value: []} = empty), do: empty
  def rotate(%D.Deque{value: [head | rest]}), do: %D.Deque{value: rest ++ [head]}
  def distinct_rows(rows), do: %D.SortedSet{value: Enum.sort(Enum.uniq(rows))}
end
