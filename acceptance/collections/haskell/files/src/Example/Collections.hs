-- User-owned LawSpec adapter.
module Example.Collections (dedupe, wordCounts, fifo, lifo, rotate, distinctRows) where

import qualified Data.Int as I
import qualified Data.Map.Strict as Map
import qualified Data.Sequence as Seq
import Data.Sequence (Seq ((:<|)), (|>))
import qualified Data.Set as Set
import qualified Data.Text as T

dedupe :: [I.Int32] -> Set.Set I.Int32
dedupe = Set.fromList

wordCounts :: [T.Text] -> Map.Map T.Text Integer
wordCounts words' = Map.fromListWith (+) [(word, 1) | word <- words']

fifo :: [I.Int8] -> Seq.Seq I.Int8
fifo = Seq.fromList

-- A Stack's top is the front of its Seq.
lifo :: [I.Int8] -> Seq.Seq I.Int8
lifo = Seq.fromList . reverse

rotate :: Seq.Seq I.Int8 -> Seq.Seq I.Int8
rotate (front :<| rest) = rest |> front
rotate empty = empty

distinctRows :: [[I.Int8]] -> Set.Set [I.Int8]
distinctRows = Set.fromList
