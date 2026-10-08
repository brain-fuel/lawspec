# ref:DEC-acceptance-with-mutants
defmodule Example.Failures do
  alias LawSpec.Data
  alias LawSpec.Abilities.Example.Failures.Gateway
  def gateway_handler(), do: %Gateway{decide: &decide/1}
  defp decide(n) when n < 0, do: %Data.DecisionBlock{}
  defp decide(n) when rem(n, 2) == 1, do: %Data.DecisionDecline{reason: "an odd amount"}
  defp decide(_n), do: %Data.DecisionApprove{}

  def refund(n) when n > 5000, do: :lawspec_beam_effects.fail(%Data.PaymentErrorTooLarge{limit: 5000})
  def refund(n), do: n

  def settle(n) when n < 0, do: :lawspec_beam_effects.fail(%Data.PaymentErrorBlocked{})
  def settle(0), do: :lawspec_beam_effects.fail(%Data.PaymentErrorDeclined{message: "there is nothing to settle"})
  def settle(n), do: n
end
