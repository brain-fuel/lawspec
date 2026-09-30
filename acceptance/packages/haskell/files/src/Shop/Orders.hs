-- User-owned LawSpec adapter.
module Shop.Orders (settlement, lineTotal, cheaper, roundDown) where

import qualified Data.Int as I
import qualified LawSpecData as Data

settlement :: Data.ShopOrdersCurrency -> Data.ShopDomainCurrency
settlement Data.ShopOrdersCurrencyUsd = Data.ShopDomainCurrencyUsd
settlement Data.ShopOrdersCurrencyGbp = Data.ShopDomainCurrencyEur

lineTotal :: Data.Line -> Data.Money
lineTotal (Data.LineLine (Data.MoneyMoney currency cents) (Data.QuantityQuantity count)) =
  Data.MoneyMoney currency (min (cents * fromIntegral count) 100000000)

cheaper :: I.Int64 -> I.Int64 -> I.Int64
cheaper = min

roundDown :: I.Int64 -> I.Int64
roundDown value = value - value `rem` 100
