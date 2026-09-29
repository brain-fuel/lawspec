module CodecGenerators where

import Hedgehog (Gen)
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import qualified CodecDomain as Domain

parcels :: Gen a -> Gen (Domain.Parcel a)
parcels = fmap Domain.parcel

positives :: Gen Domain.Positive
positives = Domain.positive <$> Gen.int8 (Range.linear 1 100)
