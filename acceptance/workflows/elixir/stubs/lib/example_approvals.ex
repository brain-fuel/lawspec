# User-owned LawSpec adapter. Implement these functions.
defmodule Example.Approvals do
  @spec approved_quickly(-9223372036854775808..9223372036854775807) :: boolean()

  def approved_quickly(_argument0) do
    raise "Not implemented: example.approvals::approvedQuickly"
  end

  @spec approval_errors(-9223372036854775808..9223372036854775807) :: [binary()]

  def approval_errors(_argument0) do raise "Not implemented: example.approvals::approvalErrors" end
end
