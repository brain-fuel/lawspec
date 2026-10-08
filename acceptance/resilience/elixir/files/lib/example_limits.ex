# ref:DEC-acceptance-with-mutants
defmodule Example.Limits do
  alias LawSpec.Data
  def admit_ticket(ticket), do: {:right, ticket}
  def reserve_seat(ticket), do: {:right, ticket}
  def charge_card(%Data.Ticket{number: n}) when n < 0, do: {:left, "declined"}
  def charge_card(ticket), do: {:right, ticket}
  def release_seat(_), do: true
  def fetch_quote(%Data.Ticket{number: n} = ticket) do
    if n == -1, do: Process.sleep(600)
    {:right, ticket}
  end
  def hedge_quote(%Data.Ticket{number: n} = ticket) do
    if n == -2 and rem(:beam_policy_probe.quote_count(), 2) == 1, do: Process.sleep(600)
    {:right, ticket}
  end
end
