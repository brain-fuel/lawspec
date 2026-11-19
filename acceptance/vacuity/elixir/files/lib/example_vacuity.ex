# User-owned LawSpec adapter.
defmodule Example.Vacuity do
  @spec shout(binary()) :: binary()
  def shout(name), do: String.upcase(name)

  @spec abbreviate(LawSpec.Data.stage()) :: binary()
  def abbreviate(stage), do: stage.token

  # Accepts only codes such as OFFER-2026-AB: no random record has one.
  @spec accepts(LawSpec.Data.proposal()) :: boolean()
  def accepts(offer), do: Regex.match?(~r/^OFFER-[0-9]{4}-[A-Z]{2}$/u, offer.code) and offer.amount > 0

  @spec describe(LawSpec.Data.proposal()) :: binary()
  def describe(offer), do: offer.code

  @spec keep(binary()) :: binary()
  def keep(key), do: key
end
