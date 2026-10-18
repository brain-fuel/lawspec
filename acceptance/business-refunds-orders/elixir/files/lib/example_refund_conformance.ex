defmodule Example.RefundConformance do
  def native_refund(%LawSpec.Data.RefundRequest{captured_amount: captured, requested_amount: requested, flagged: flagged}) do
    cond do
      requested == 0 -> %LawSpec.Data.RefundDecisionApproved{}
      requested > captured -> %LawSpec.Data.RefundDecisionRejected{}
      flagged -> %LawSpec.Data.RefundDecisionReviewRequired{}
      true -> %LawSpec.Data.RefundDecisionApproved{}
    end
  end
end
