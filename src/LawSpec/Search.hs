-- LawSpec's own search over a law's inputs, beside the property-testing
-- libraries: the failure database keeps a failing case's inputs in the wire
-- encoding (docs/reference/language/distribution.md#the-wire-encoding) and
-- replays them first, and `target maximize` climbs over generation seeds and
-- sizes where a library has no targeted search of its own.
--
-- Both need each input's descriptor, the form every runtime's generator,
-- shrinker and wire codec read (LawSpec.MachineSpec): its data types first,
-- then the input's own form, an integer narrowed to the constant bounds of
-- its refinements. A law with an input no descriptor covers (a float, a
-- handle, a generic data type) has no search; its failures are kept by seed.
module LawSpec.Search (lawDescriptors, searchable, Kept(..), keptFor) where

import qualified LawSpec.Core as C
import LawSpec.Common (keptValues)
import LawSpec.Bounds (bounds)
import LawSpec.MachineSpec (describe, describeRefined, narrow)
import Control.Monad (guard)
import Data.List (nub, sort)
import qualified Data.Map.Strict as M
import LawSpec.Blake3 (blake3Hex, blake3Text)
import LawSpec.Core.Identity (Encoded(..), Resolver(..), encode)
import LawSpec.Core.Types (substitute)

lawDescriptors :: Int -> [C.DataDeclaration] -> C.Property -> Maybe [String]
lawDescriptors bits datas p
  | null (C.propertyInputs p) = Nothing
  | otherwise = mapM one (C.propertyInputs p)
  where
    one q = let b = C.quantifiedBinder q in case describe bits datas [] (C.binderType b) of
      Right (d, table) -> Just (unwords (map snd (reverse table) ++ [narrow (bounds (C.binderId b) (C.quantifiedPredicates q)) d]))
      Left _ -> Nothing

-- Whether a law takes part in the search: it has generated cases (not a
-- finite domain), every input has a descriptor, and its harness neither
-- skips it nor expects it to fail.
searchable :: Bool -> C.Property -> Bool
searchable finite p = not finite && C.harnessSkip h == Nothing && C.harnessKnownDiscrepancy h == Nothing
  where h = C.propertyHarness p

-- | What the kept-values store needs of a law: the descriptors of its inputs
-- (the wire encoding of values of restricted types, see
-- docs/reference/language/distribution.md#the-wire-encoding) and one spec
-- line, "KEY CAP TAG...": the key is a hash of the descriptors and of the
-- definitions the inputs reach, restrictions included, so a changed
-- restriction makes the old values unreachable; CAP is how many values a key
-- keeps; the tags are the constructors of the restricted types, by which a
-- run recognises a case that holds a value of one.
data Kept = Kept { keptDescriptors :: [String], keptSpec :: String } deriving (Eq, Show)

-- | Nothing when the law has no restricted type in its inputs, an input has
-- no descriptor (a float, a handle), or the cap is 0.
keptFor :: Int -> [C.DataDeclaration] -> C.Property -> Maybe Kept
keptFor bits datas p = do
  let cap = keptValues (C.propertyGeneration p)
      inputs = C.propertyInputs p
  guard (cap > 0 && not (null inputs))
  descriptors <- mapM describeInput inputs
  let reached = M.elems (foldl reach M.empty [C.binderType (C.quantifiedBinder q) | q <- inputs])
      restricted = [d | d <- reached, any (not . null . C.constructorPredicates) (C.dataConstructors d)]
      tags = nub (sort [C.idText (C.constructorId c) | d <- restricted, c <- C.dataConstructors d])
      resolver = Resolver (const Nothing) (const Nothing)
      definitions = sort [blake3Hex (semanticBytes (encode resolver d)) | d <- reached]
  guard (not (null tags))
  pure (Kept descriptors (unwords (key descriptors definitions : show cap : tags)))
  where
    describeInput q = let b = C.quantifiedBinder q in case describeRefined bits datas [] (C.binderType b) of
      Right (d, table) -> Just (unwords (map snd (reverse table) ++ [narrow (bounds (C.binderId b) (C.quantifiedPredicates q)) d]))
      Left _ -> Nothing
    key descriptors definitions = take 32 (blake3Text (unlines (descriptors ++ definitions)))
    reach seen ty = case ty of
      C.Constructor n arguments
        | n `elem` ["List", "Maybe", "Either"] -> foldl reach seen [t | C.TypeArgument t <- arguments]
        | not (M.member ty seen), (d : _) <- [d | d <- datas, C.idText (C.dataId d) == n] ->
            let env = M.fromList (zip (C.dataParameters d) [t | C.TypeArgument t <- arguments])
            in foldl reach (M.insert ty d seen)
                 [substitute env (C.binderType f) | c <- C.dataConstructors d, f <- C.constructorFields c]
      _ -> seen
