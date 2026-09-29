module HaskellBoundCodecGeneratorsCheck (checkFactories) where

import Control.Monad (unless)
import Data.List (find)
import qualified Hedgehog.Gen as PublicGen
import qualified Hedgehog.Range as Range
import qualified Hedgehog.Internal.Gen as Gen
import qualified Hedgehog.Internal.Seed as Seed
import qualified Hedgehog.Internal.Tree as Tree
import qualified LawSpecNativeGenerators as Native
import qualified LawSpecDataSchema as DataSchema
import qualified LawSpecSchema as S
import qualified LawSpecRuntime as LS

checkFactories :: Int -> IO ()
checkFactories bits = do
  symbols <- LS.newSymbolContext
  let schema = either error id DataSchema.schema
      factories = Native.factories symbols schema bits
      factory = maybe (error "missing Parcel factory") id
        (lookup "native.codecs::type::Parcel" factories)
      bytes = LS.SInteger "Int8" <$> PublicGen.integral (Range.linear 1 100)
      parcels = either error id (factory
        (S.Named "native.codecs::type::Parcel" [S.Named "Int8" []]) [bytes])
      stored value = case value of
        LS.SData _ [LS.SInteger _ integer] -> integer
        _ -> error "invalid generated Parcel"
      fails = (> 60) . stored . Tree.treeValue
      trees = [tree | seed <- [1 .. 100],
        Just tree <- [Gen.evalGen 100 (Seed.from seed) parcels]]
      shrink tree = case find fails (Tree.treeChildren tree) of
        Just child -> shrink child
        Nothing -> stored (Tree.treeValue tree)
      result = case find fails trees of
        Just tree -> shrink tree
        Nothing -> error "native codec factory produced no failing sample"
  unless (result == 61)
    (error "generic codec hooks lost native child shrinking")
  putStrLn "Haskell generic codec hooks retain native shrinking to 61"
