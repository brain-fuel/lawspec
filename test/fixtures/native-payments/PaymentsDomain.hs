module PaymentsDomain where

import Data.Ratio ((%))
import Data.Text (Text)
import LawSpecRuntime (Decimal(..))

data CurrencyCode = Dollars | Euros | Pounds deriving (Eq, Show)
-- Deliberately reverse the logical field order.
data Price = Price { unit :: CurrencyCode, major :: Decimal } deriving (Eq, Show)
data PaymentStatus = Settled { price :: Price } | Rejected { explanation :: Text }
  deriving (Eq, Show)

addFee :: Price -> Price
addFee value = case major value of
  Decimal amount -> value { major = Decimal (amount + 1 % 5) }

restore :: PaymentStatus -> PaymentStatus
restore value = value

store :: [Maybe PaymentStatus] -> [Maybe PaymentStatus]
store values = values
