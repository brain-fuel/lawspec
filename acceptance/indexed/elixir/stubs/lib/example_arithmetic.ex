# User-owned LawSpec adapter. Implement these functions.
defmodule Example.Arithmetic do
  @spec mirror(LawSpec.Data.perfect()) :: LawSpec.Data.perfect()

  def mirror(_perfect) do
    raise "Not implemented: example.arithmetic::mirror"
  end

  @spec area(LawSpec.Data.grid()) :: integer()

  def area(_grid) do
    raise "Not implemented: example.arithmetic::area"
  end

  @spec duplicate(LawSpec.Data.row()) :: LawSpec.Data.halves()

  def duplicate(_row) do
    raise "Not implemented: example.arithmetic::duplicate"
  end

  @spec count_pairs(LawSpec.Data.row()) :: LawSpec.Data.pairs()

  def count_pairs(_row) do
    raise "Not implemented: example.arithmetic::countPairs"
  end

  @spec drop_first(LawSpec.Data.row()) :: LawSpec.Data.rest()

  def drop_first(_row) do
    raise "Not implemented: example.arithmetic::dropFirst"
  end
end
