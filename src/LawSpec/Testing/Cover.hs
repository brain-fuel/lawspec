-- | Ordered finite cases as shared suffixes and integer intervals. A cover is
-- data for a runtime enumerator, not one copy of a law's check per case.
-- Compression preserves case order, correlations and duplicate observations.
-- ref:DEC-planned-generation
module LawSpec.Testing.Cover
  ( FiniteCover(..), CaseDomain(..), compressCases, coverCases, coverCount
  , domainValues, domainCount, mapCoverValues
  ) where

import Data.List (groupBy)
import Data.Binary (Binary)
import GHC.Generics (Generic)
import LawSpec.CorePersist ()
import LawSpec.Core.Value (Value(..))
import LawSpec.Scalar (Scalar(..))

-- | A completed prefix may occur more than once. Alternatives are visited in
-- order; each value is followed by every case in its suffix before advancing.
data FiniteCover
  = Complete Int
  | Alternatives [(CaseDomain, FiniteCover)]
  deriving (Eq, Show, Generic)

-- | Inclusive mathematical endpoints need no overflowing upper-plus-one
-- sentinel when a target enumerates the maximum Int8 or UInt8 value.
data CaseDomain
  = Values [Value]
  | IntegerInterval String Integer Integer
  deriving (Eq, Show, Generic)

instance Binary FiniteCover
instance Binary CaseDomain

-- | The planner owns admission and completeness. Compression never adds a
-- Cartesian combination and only joins adjacent, identical suffixes.
compressCases :: [[Value]] -> Either String FiniteCover
compressCases rows
  | any ((/= arity) . length) rows = Left "finite cover cases have different arities"
  | otherwise = Right (build rows)
  where
    arity = case rows of [] -> 0; row : _ -> length row
    build [] = Alternatives []
    build entries
      | all null entries = Complete (length entries)
      | otherwise = Alternatives (merge branches)
      where
        groups = groupBy (\a b -> take 1 a == take 1 b) entries
        branches = [(first, build (map (drop 1) same)) | same@((first : _) : _) <- groups]
    merge [] = []
    merge ((value, suffix) : rest) =
      let (same, remaining) = span ((== suffix) . snd) rest
      in (compactDomain (value : map fst same), suffix) : merge remaining

compactDomain :: [Value] -> CaseDomain
compactDomain values@(ScalarValue (SInteger name first) : rest)
  | length values >= 3
  , and [value == ScalarValue (SInteger name expected) | (expected, value) <- zip [first + 1 ..] rest] =
      IntegerInterval name first (first + toInteger (length rest))
compactDomain values = Values values

domainValues :: CaseDomain -> [Value]
domainValues (Values values) = values
domainValues (IntegerInterval name first last') = [ScalarValue (SInteger name n) | n <- [first .. last']]

domainCount :: CaseDomain -> Integer
domainCount (Values values) = toInteger (length values)
domainCount (IntegerInterval _ first last') = max 0 (last' - first + 1)

-- | A lazy compatibility view for the reference evaluator. Native emitters
-- consume the cover and emit one runtime loop over its data instead.
coverCases :: FiniteCover -> [[Value]]
coverCases (Complete count) = replicate count []
coverCases (Alternatives alternatives) =
  [value : suffix | (domain, rest) <- alternatives, value <- domainValues domain, suffix <- coverCases rest]

coverCount :: FiniteCover -> Integer
coverCount (Complete count) = toInteger count
coverCount (Alternatives alternatives) = sum [domainCount domain * coverCount rest | (domain, rest) <- alternatives]

-- | Witness attachment changes structural values but must preserve every
-- observation, including duplicates. Recompress mapped integer domains only
-- after checking their complete ordered values.
mapCoverValues :: (Value -> Value) -> FiniteCover -> FiniteCover
mapCoverValues _ cover@(Complete _) = cover
mapCoverValues f (Alternatives alternatives) = Alternatives
  [(compactDomain (map f (domainValues domain)), mapCoverValues f rest) | (domain, rest) <- alternatives]
