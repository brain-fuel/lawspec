module Main where

import Control.Exception (SomeException, displayException, evaluate, try)
import Control.Monad (forM_, unless)
import Data.Int (Int8)
import Data.List (find, isInfixOf)
import Hedgehog (Gen)
import qualified Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import qualified Hedgehog.Internal.Gen as Internal
import qualified Hedgehog.Internal.Seed as Seed
import qualified Hedgehog.Internal.Tree as Tree
import qualified LawSpecRuntime as LS
import qualified LawSpecSchema as S
import qualified LawSpecCodecs as C
import qualified LawSpecDataStrategies as G

right :: Either String a -> a
right = either error id

assert :: String -> Bool -> IO ()
assert label condition = unless condition (error label)

samples :: Gen a -> [Tree.Tree a]
samples generator = [tree | seed <- [1 .. 100],
  Just tree <- [Internal.evalGen 100 (Seed.from seed) generator]]

expectError :: String -> LS.Scalar -> IO ()
expectError fragment value = do
  result <- try (evaluate (LS.forceScalar value)) :: IO (Either SomeException ())
  case result of
    Left problem -> assert (displayException problem)
      (fragment `isInfixOf` displayException problem)
    Right _ -> error "invalid native value escaped validation"

shrinkFailure :: Tree.Tree LS.Scalar -> LS.Scalar
shrinkFailure tree = case find (fails . Tree.treeValue) (Tree.treeChildren tree) of
  Nothing -> Tree.treeValue tree
  Just child -> shrinkFailure child
  where
    fails (LS.SInteger _ value) = value > 60
    fails _ = False

main :: IO ()
main = forM_ [32, 64] $ \bits -> do
  let schema = right (S.create [] ["Int8"])
      reference = S.Named "Int8" []
      codec = C.integerCodec schema bits "Int8" :: C.Codec Int8
      build factory = right (G.checkedStrategyWith [("Int8",factory)]
        schema reference bits 4 Nothing [LS.SInteger "Int8" 0]
        (G.primitiveStrategy bits))
      factory _ [] = Right (G.nativeValues codec (Gen.int8 (Range.linear 1 100)))
      factory _ _ = Left "unexpected generator arguments"
      generated = samples (build factory)
      numbers = [n | tree <- generated,LS.SInteger _ n <- [Tree.treeValue tree]]
  assert "native factory did not run" (length numbers == 100 && all (> 0) numbers)
  let failing = find (\tree -> case Tree.treeValue tree of
        LS.SInteger _ n -> n > 60
        _ -> False) generated
  case failing of
    Just tree -> case shrinkFailure tree of
      LS.SInteger _ 61 -> pure ()
      _ -> error "native integer shrink tree changed"
    Nothing -> error "no failing sample"
  let empty _ _ = Right Gen.discard
  assert "exhausted native factory acquired fallback witnesses" (null (samples (build empty)))
  let broad = C.integerCodec schema bits "Int8" :: C.Codec Integer
      bad = G.nativeValues broad (pure 128)
  expectError "native generator" (Tree.treeValue (head (samples bad)))
  passed <- Hedgehog.check $ Hedgehog.withTests 1 $ Hedgehog.property $ do
    value <- Hedgehog.forAllWith (const "native candidate") bad
    Hedgehog.assert (case value of LS.SInteger _ _ -> True; _ -> False)
  assert "invalid custom samples must fail a property" (not passed)
  let shrinking = G.nativeValues broad (Gen.shrink (\n -> [128 | n == 2]) (pure 2))
      tree = head (samples shrinking)
  case Tree.treeValue tree of
    LS.SInteger _ 2 -> pure ()
    _ -> error "valid root changed"
  expectError "native generator" (Tree.treeValue (head (Tree.treeChildren tree)))
  let arguments = G.nativeArguments codec (LS.SInteger "Int8" <$> Gen.integral (Range.linear 1 100))
      remapped = G.nativeValues codec arguments
  assert "child generator conversions removed shrinking"
    (any (not . null . Tree.treeChildren) (samples remapped))
  let phantomSchema = right (S.create
        [S.Definition "Empty" 0 [],
         S.Definition "Phantom" 1 [S.Constructor "Phantom::Phantom"
           [S.Field "value" (S.Named "Int8" [])]]] ["Int8"])
      phantomType = S.Named "Phantom" [S.Named "Empty" []]
      wrap value = LS.SData "Phantom::Phantom" [LS.SInteger "Int8" value]
      phantom _ [_] = Right (wrap <$> Gen.integral (Range.linear 40 100))
      phantom _ _ = Left "expected one phantom parameter"
      demand _ [child] = Right (const (wrap 40) <$> child)
      demand _ _ = Left "expected one empty parameter"
      buildPhantom factory = right (G.checkedStrategyWith [("Phantom",factory)]
        phantomSchema phantomType bits 32 Nothing [] (G.primitiveStrategy bits))
      phantomTrees = samples (buildPhantom phantom)
      smallest tree = case Tree.treeChildren tree of
        [] -> Tree.treeValue tree
        child:_ -> smallest child
  assert "unused empty argument blocked phantom factory" (length phantomTrees == 100)
  assert "phantom factory lost native shrinking"
    (all (\tree -> case smallest tree of
      LS.SData "Phantom::Phantom" [LS.SInteger _ 40] -> True
      _ -> False) phantomTrees)
  assert "empty argument supplied a sample" (null (samples (buildPhantom demand)))
  assert "empty root must remain uninhabited" (case G.checkedStrategyWith []
    phantomSchema (S.Named "Empty" []) bits 32 Nothing [] (G.primitiveStrategy bits) of
      Left _ -> True
      Right _ -> False)
  putStrLn ("Haskell native generator trees passed for " ++ show bits ++ " bits")
