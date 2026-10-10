# ref:DEC-portable-seeded-generation ref:DEC-acceptance-with-mutants
defmodule Example.Generation do
  def generated(text, seed, size, count), do: :beam_generation_support.generated(text, seed, size, count)
  def shrunk(text, seed, size), do: :beam_generation_support.shrunk(text, seed, size)
end
