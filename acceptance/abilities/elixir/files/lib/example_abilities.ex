# User-owned native functions and production ability interface.
defmodule Example.Abilities do
  alias LawSpec.Data
  alias LawSpec.Abilities.Example.Abilities.Gateway

  def charge(gateway, cents) do
    case gateway.authorize.(cents) do
      %Data.PaymentApproved{cents: approved} ->
        %Data.Receipt{cents: paid} = gateway.capture.(approved)
        paid == cents
      %Data.PaymentDeclined{} -> false
    end
  end

  def gateway_handler() do
    %Gateway{
      authorize: fn cents ->
        if cents < 0, do: %Data.PaymentDeclined{}, else: %Data.PaymentApproved{cents: cents}
      end,
      capture: fn cents -> %Data.Receipt{cents: cents} end,
      fee: fn -> 25 end
    }
  end
end
