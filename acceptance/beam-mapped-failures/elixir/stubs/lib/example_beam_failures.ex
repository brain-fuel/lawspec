# User-owned LawSpec adapter. Implement these functions.
defmodule Example.BeamFailures do
  @spec refund(-2_147_483_648..2_147_483_647) :: -2_147_483_648..2_147_483_647

  def refund(_int32) do
    raise "Not implemented: example.beamFailures::refund"
  end

  @spec checked_limit(-2_147_483_648..2_147_483_647) :: -2_147_483_648..2_147_483_647

  def checked_limit(_int32) do
    raise "Not implemented: example.beamFailures::checkedLimit"
  end
end
