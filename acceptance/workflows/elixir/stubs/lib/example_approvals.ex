# User-owned LawSpec adapter. Implement these functions.
defmodule Example.Approvals do
  @spec approved_quickly(-9_223_372_036_854_775_808..9_223_372_036_854_775_807) :: boolean()

  def approved_quickly(_int64) do
    raise "Not implemented: example.approvals::approvedQuickly"
  end

  @spec approval_errors(-9_223_372_036_854_775_808..9_223_372_036_854_775_807) :: [binary()]

  def approval_errors(_int64) do
    raise "Not implemented: example.approvals::approvalErrors"
  end
end
