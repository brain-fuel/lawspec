# User-owned LawSpec adapter. Implement these functions.
defmodule Example.Limits do
  @spec admit_ticket(LawSpec.Data.ticket()) :: {:left, binary()} | {:right, LawSpec.Data.ticket()}

  def admit_ticket(_argument0) do raise "Not implemented: example.limits::admitTicket" end

  @spec reserve_seat(LawSpec.Data.ticket()) :: {:left, binary()} | {:right, LawSpec.Data.ticket()}

  def reserve_seat(_argument0) do raise "Not implemented: example.limits::reserveSeat" end

  @spec charge_card(LawSpec.Data.ticket()) :: {:left, binary()} | {:right, LawSpec.Data.ticket()}

  def charge_card(_argument0) do raise "Not implemented: example.limits::chargeCard" end

  @spec release_seat(LawSpec.Data.ticket()) :: boolean()

  def release_seat(_argument0) do raise "Not implemented: example.limits::releaseSeat" end

  @spec fetch_quote(LawSpec.Data.ticket()) :: {:left, binary()} | {:right, LawSpec.Data.ticket()}

  def fetch_quote(_argument0) do raise "Not implemented: example.limits::fetchQuote" end

  @spec hedge_quote(LawSpec.Data.ticket()) :: {:left, binary()} | {:right, LawSpec.Data.ticket()}

  def hedge_quote(_argument0) do raise "Not implemented: example.limits::hedgeQuote" end
end
