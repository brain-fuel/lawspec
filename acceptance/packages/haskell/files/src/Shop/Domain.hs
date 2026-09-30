-- User-owned LawSpec adapter.
module Shop.Domain (convert) where

import qualified LawSpecData as Data

-- One-to-one rates keep the example exact.
convert :: Data.ShopDomainCurrency -> Data.Money -> Data.Money
convert currency (Data.MoneyMoney _ cents) = Data.MoneyMoney currency cents
