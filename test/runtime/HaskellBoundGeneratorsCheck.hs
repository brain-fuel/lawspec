module HaskellBoundGeneratorsCheck (checkFactories) where

import Control.Monad (unless)
import Data.List (find)
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
      get name = maybe (error ("missing factory " ++ name)) id (lookup name factories)
      money = either error id (get "example.payments::type::Money"
        (S.Named "example.payments::type::Money" []) [])
      byteType = S.Named "Int8" []
      bytes = either error id (get "Int8" byteType [])
      boxes = either error id (get "native.shapes::type::Box"
        (S.Named "native.shapes::type::Box" [byteType]) [bytes])
      trees generator = [tree | seed <- [1 .. 100],
        Just tree <- [Gen.evalGen 100 (Seed.from seed) generator]]
      shrink fails tree = case find (fails . Tree.treeValue) (Tree.treeChildren tree) of
        Just child -> shrink fails child
        Nothing -> Tree.treeValue tree
      failing fails generator = case find (fails . Tree.treeValue) (trees generator) of
        Just tree -> shrink fails tree
        Nothing -> error "native distribution produced no failing sample"
      amount value = case value of
        LS.SData _ [LS.SDecimal coefficient exponent, _] ->
          fromInteger coefficient * (10 ^^ exponent) :: Rational
        _ -> error "invalid generated Money"
      stored value = case value of
        LS.SData _ [LS.SInteger _ integer] -> integer
        _ -> error "invalid generated Box"
  unless (amount (failing ((> 8 / 5) . amount) money) == 161 / 100)
    (error "emitted Money factory did not retain native shrinking")
  unless (stored (failing ((> 12) . stored) boxes) == 13)
    (error "emitted generic factory did not retain child shrinking")
  putStrLn "Emitted Haskell factories retain Money and generic Box shrinking"
