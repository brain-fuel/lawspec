-- User-owned LawSpec adapter.
module Shop.Orders (settlement, lineTotal, cheaper, roundDown, classify) where

import qualified Data.Int as I
import qualified LawSpecData as Data

settlement :: Data.ShopOrdersCurrency -> Data.ShopDomainCurrency
settlement Data.ShopOrdersCurrencyUsd = Data.ShopDomainCurrencyUsd
settlement Data.ShopOrdersCurrencyGbp = Data.ShopDomainCurrencyEur

lineTotal :: Data.Line -> Data.Money
lineTotal (Data.Line (Data.Money currency cents) (Data.Quantity count)) =
  Data.Money currency (min (cents * fromIntegral count) 100000000)

cheaper :: I.Int64 -> I.Int64 -> I.Int64
cheaper = min

roundDown :: I.Int64 -> I.Int64
roundDown value = value - value `rem` 100

-- Version 2 of shop.tax: no tax on nothing, the high band from 100.00.
classify :: I.Int64 -> Data.ShopTaxV2x0x0RatesBand
classify value0
  | value0 <= 0 = Data.ShopTaxV2x0x0RatesBandZero
  | value0 < 10000 = Data.ShopTaxV2x0x0RatesBandLow
  | otherwise = Data.ShopTaxV2x0x0RatesBandHigh
