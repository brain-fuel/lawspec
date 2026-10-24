-- User-owned LawSpec adapter for shop.domain: implement each function.
module Shop.Domain where

import qualified Data.ByteString as B
import qualified Data.Complex as C
import qualified Data.Int as I
import qualified Data.Text as T
import qualified Data.Word as W
import qualified LawSpecData as Data
import qualified LawSpecRuntime as LS
import Prelude
import qualified Prelude as P

-- convert :: shop.domain::type::Currency -> shop.domain::type::Money ->
-- shop.domain::type::Money — examples/packages/shop-domain/src/domain.lawspec:47
convert :: Data.ShopDomainCurrency -> Data.Money -> Data.Money
convert _ _ = P.error "convert"
