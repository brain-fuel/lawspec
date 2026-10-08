# User-owned LawSpec adapter. Implement these functions.
defmodule Example.Indexed do
  @spec replicate(integer(), -128..127) :: LawSpec.Data.vec(-128..127)

  def replicate(_argument0, _argument1) do raise "Not implemented: example.indexed::replicate" end

  @spec append(LawSpec.Data.vec(-128..127), LawSpec.Data.vec(-128..127)) ::
    LawSpec.Data.vec(-128..127)

  def append(_argument0, _argument1) do raise "Not implemented: example.indexed::append" end

  @spec zip(LawSpec.Data.vec(-128..127), LawSpec.Data.vec(boolean())) :: LawSpec.Data.vec(boolean())

  def zip(_argument0, _argument1) do raise "Not implemented: example.indexed::zip" end

  @spec flatten(LawSpec.Data.tree(-128..127)) :: LawSpec.Data.vec(-128..127)

  def flatten(_argument0) do raise "Not implemented: example.indexed::flatten" end
end
