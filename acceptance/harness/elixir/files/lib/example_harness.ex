# ref:REQ-harness-units ref:DEC-tests-cite-requirements
defmodule Example.Harness do
  def discount(%LawSpec.Data.Order{items: items, total: total}) when items > 10, do: div(total, 10)
  def discount(_), do: 0
  def round_cents(cents), do: div(cents + 4, 10) * 10
  def book(ledger, cents), do: ledger.accept.(cents)
  def ledger_handler(), do: %LawSpec.Abilities.Example.Harness.Ledger{accept: fn cents -> cents > 0 end}
end
