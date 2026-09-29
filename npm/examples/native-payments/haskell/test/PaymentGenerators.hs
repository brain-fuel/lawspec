module PaymentGenerators where

import Data.Ratio ((%))
import Hedgehog (Gen)
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import LawSpecRuntime (Decimal(..))
import PaymentsDomain

prices :: Gen Price
prices = (\cents -> Price Euros (Decimal (cents % 100))) <$>
  Gen.integral (Range.linear 100 200)
