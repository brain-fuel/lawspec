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
module LawSpec.Search (lawDescriptors, searchable) where

import qualified LawSpec.Core as C
import LawSpec.Bounds (bounds)
import LawSpec.MachineSpec (describe, narrow)

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
searchable finite p = not finite && C.harnessSkip h == Nothing && C.harnessKnownFailing h == Nothing
  where h = C.propertyHarness p
