# User-owned LawSpec adapter. Implement these functions.
defmodule Example.BeamFailures do
  @spec refund(-2147483648..2147483647) :: -2147483648..2147483647

  def refund(_argument0) do raise "Not implemented: example.beamFailures::refund" end

  @spec checked_limit(-2147483648..2147483647) :: -2147483648..2147483647

  def checked_limit(_argument0) do raise "Not implemented: example.beamFailures::checkedLimit" end
end
