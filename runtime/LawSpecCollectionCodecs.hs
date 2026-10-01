-- Native bridges for the built-in collections: a Set is a Data.Set.Set, a
-- KeyVal a Data.Map.Map, and a Queue, Stack or Deque a Data.Sequence.Seq
-- from its first item (a Stack's top). These need the containers package.
module LawSpecCollectionCodecs
  ( setCodecWith, keyValCodecWith, sequenceCodecWith
  ) where

import Data.Foldable (toList)
import qualified Data.Map.Strict as Map
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import qualified LawSpecRuntime as LS
import qualified LawSpecSchema as S
import LawSpecCodecs (Codec, codecWith, decode, encode, reference)

collections :: String
collections = "lawspec.collections::type::"

items :: LS.Scalar -> Either String [LS.Scalar]
items (LS.SData _ [LS.SList values]) = Right values
items _ = Left "invalid checked collection"

setCodecWith :: Ord a => Maybe LS.SymbolContext -> S.Schema -> Int -> Codec a -> Codec (Set.Set a)
setCodecWith scope schema bits element = codecWith scope schema bits
  (S.Named (collections ++ "Set") [reference element]) fromValue toValue
  where
    fromValue value = Set.fromList <$> (items value >>= mapM (decode element))
    toValue set = do
      values <- mapM (encode element) (Set.toList set)
      pure (LS.SData (collections ++ "Set::SetItems") [LS.SList (LS.canonicalItems False values)])

keyValCodecWith :: Ord k => Maybe LS.SymbolContext -> S.Schema -> Int -> Codec k -> Codec v -> Codec (Map.Map k v)
keyValCodecWith scope schema bits keys values = codecWith scope schema bits
  (S.Named (collections ++ "KeyVal") [reference keys, reference values]) fromValue toValue
  where
    fromValue value = Map.fromList <$> (items value >>= mapM entry)
    entry (LS.SData _ [k, v]) = (,) <$> decode keys k <*> decode values v
    entry _ = Left "invalid checked KeyVal entry"
    toValue map' = do
      entries <- mapM (\(k, v) -> (\a b -> LS.SData (collections ++ "Entry::Entry") [a, b]) <$> encode keys k <*> encode values v)
        (Map.toList map')
      pure (LS.SData (collections ++ "KeyVal::KeyValEntries") [LS.SList (LS.canonicalItems True entries)])

sequenceCodecWith :: String -> Maybe LS.SymbolContext -> S.Schema -> Int -> Codec a -> Codec (Seq.Seq a)
sequenceCodecWith name scope schema bits element = codecWith scope schema bits
  (S.Named (collections ++ name) [reference element]) fromValue toValue
  where
    fromValue value = Seq.fromList <$> (items value >>= mapM (decode element))
    toValue sequence' = do
      values <- mapM (encode element) (toList sequence')
      pure (LS.SData (collections ++ name ++ "::" ++ name ++ "Items") [LS.SList values])
