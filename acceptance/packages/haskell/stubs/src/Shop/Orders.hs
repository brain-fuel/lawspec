-- User-owned LawSpec adapter.
module Shop.Orders where

import Prelude
import qualified Prelude as P
import qualified Data.Int as I
import qualified Data.Word as W
import qualified Data.Text as T
import qualified Data.ByteString as B
import qualified Data.Complex as C
import qualified LawSpecRuntime as LS
import qualified LawSpecData as Data

-- (shop.orders::type::Currency -> shop.domain::type::Currency)
settlement :: Data.ShopOrdersCurrency -> Data.ShopDomainCurrency
settlement _ = error "settlement"

-- (shop.orders::type::Line -> shop.domain::type::Money)
lineTotal :: Data.Line -> Data.Money
lineTotal _ = error "lineTotal"

-- (Int64 -> (Int64 -> Int64))
cheaper :: I.Int64 -> I.Int64 -> I.Int64
cheaper _ _ = error "cheaper"

-- (Int64 -> Int64)
roundDown :: I.Int64 -> I.Int64
roundDown _ = error "roundDown"

-- (Int64 -> shop.tax.v2_0_0.rates::type::Band)
classify :: I.Int64 -> Data.ShopTaxV200RatesBand
classify _ = error "classify"
