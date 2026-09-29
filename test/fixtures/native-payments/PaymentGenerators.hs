module PaymentGenerators where

import Data.Int (Int8)
import Data.Ratio ((%))
import Hedgehog (Gen)
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import LawSpecRuntime (Decimal(..))
import PaymentsDomain
import ShapesDomain

prices :: Gen Price
prices = (\cents -> Price Euros (Decimal (cents % 100))) <$>
  Gen.integral (Range.linear 100 200)

boxes :: Gen a -> Gen (Wrapped a)
boxes = fmap Wrapped

bytes :: Gen Int8
bytes = Gen.int8 (Range.linear 6 20)

seals :: Gen Seal
seals = error "finite singleton must be enumerated without invoking its factory"
