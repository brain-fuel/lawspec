-- User-owned LawSpec adapter for shop.orders: implement each function.
module Shop.Orders where

import qualified Data.ByteString as B
import qualified Data.Complex as C
import qualified Data.Int as I
import qualified Data.Text as T
import qualified Data.Word as W
import qualified LawSpecData as Data
import qualified LawSpecRuntime as LS
import Prelude
import qualified Prelude as P

-- settlement :: shop.orders::type::Currency -> shop.domain::type::Currency —
-- orders.lawspec:13
settlement :: Data.ShopOrdersCurrency -> Data.ShopDomainCurrency
settlement _ = P.error "settlement"

-- lineTotal :: shop.orders::type::Line -> shop.domain::type::Money —
-- orders.lawspec:14
lineTotal :: Data.Line -> Data.Money
lineTotal _ = P.error "lineTotal"

-- cheaper :: Int64 -> Int64 -> Int64 — orders.lawspec:17
cheaper :: I.Int64 -> I.Int64 -> I.Int64
cheaper _ _ = P.error "cheaper"

-- roundDown :: Int64 -> Int64 — orders.lawspec:18
roundDown :: I.Int64 -> I.Int64
roundDown _ = P.error "roundDown"

-- classify :: Int64 -> shop.tax.v2x0x0.rates::type::Band — orders.lawspec:19
classify :: I.Int64 -> Data.ShopTaxV2x0x0RatesBand
classify _ = P.error "classify"
