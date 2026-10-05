-- User-owned LawSpec adapters for the tables example.
module Example.Tables where

import Prelude
import qualified Data.Int as I
import qualified Data.Text as T

-- (Int32 -> (Int32 -> Int32))
shippingCost :: I.Int32 -> I.Int32 -> I.Int32
shippingCost kilograms kilometres = kilograms * kilometres + 5 * kilograms

-- (Int32 -> Text)
label :: I.Int32 -> T.Text
label parcel = T.pack ("parcel " ++ show parcel)
