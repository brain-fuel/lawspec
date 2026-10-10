# ref:DEC-acceptance-with-mutants
defmodule Shop.Orders do
  alias LawSpec.Data, as: D
  def settlement(%D.ShopOrdersTypeCurrencyUsd{}), do: %D.ShopDomainTypeCurrencyUsd{}
  def settlement(%D.ShopOrdersTypeCurrencyGbp{}), do: %D.ShopDomainTypeCurrencyEur{}
  def line_total(%D.Line{price: price, quantity: quantity}) do
    %D.Money{currency: price.currency, cents: min(price.cents * quantity.value, 100000000)}
  end
  def cheaper(a, b), do: min(a, b)
  def round_down(value), do: value - rem(value, 100)
  def classify(value) when value <= 0, do: %D.ShopTaxV2x0x0RatesTypeBandZero{}
  def classify(value) when value < 10000, do: %D.ShopTaxV2x0x0RatesTypeBandLow{}
  def classify(_), do: %D.ShopTaxV2x0x0RatesTypeBandHigh{}
end
