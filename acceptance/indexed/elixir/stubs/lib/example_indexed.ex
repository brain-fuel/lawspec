# User-owned LawSpec adapter. Implement these functions.
defmodule Example.Indexed do
  @spec replicate(non_neg_integer(), -128..127) :: LawSpec.Data.vec(-128..127)

  def replicate(_big_u_int, _int8) do
    raise "Not implemented: example.indexed::replicate"
  end

  @spec append(LawSpec.Data.vec(-128..127), LawSpec.Data.vec(-128..127)) ::
          LawSpec.Data.vec(-128..127)

  def append(_vec_int8, _vec_int8_2) do
    raise "Not implemented: example.indexed::append"
  end

  @spec zip(LawSpec.Data.vec(-128..127), LawSpec.Data.vec(boolean())) ::
          LawSpec.Data.vec(boolean())

  def zip(_vec_int8, _vec_bool) do
    raise "Not implemented: example.indexed::zip"
  end

  @spec flatten(LawSpec.Data.tree(-128..127)) :: LawSpec.Data.vec(-128..127)

  def flatten(_tree_int8) do
    raise "Not implemented: example.indexed::flatten"
  end
end
