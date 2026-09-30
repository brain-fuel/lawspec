-- User-owned LawSpec adapter.
module Shop.Domain where

import Prelude
import qualified Prelude as P
import qualified Data.Int as I
import qualified Data.Word as W
import qualified Data.Text as T
import qualified Data.ByteString as B
import qualified Data.Complex as C
import qualified LawSpecRuntime as LS
import qualified LawSpecData as Data

-- (shop.domain::type::Currency -> (shop.domain::type::Money ->
-- shop.domain::type::Money))
convert :: Data.ShopDomainCurrency -> Data.Money -> Data.Money
convert _ _ = error "convert"
