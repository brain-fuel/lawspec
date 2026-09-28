module Main where

import Control.Exception (SomeException, displayException, evaluate, try)
import Control.Monad (forM_, unless)
import Data.List (find, isInfixOf)
import System.Timeout (timeout)
import Hedgehog (Gen)
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import qualified Hedgehog.Internal.Gen as Internal
import qualified Hedgehog.Internal.Seed as Seed
import qualified Hedgehog.Internal.Tree as Tree
import qualified LawSpecRuntime as LS
import qualified LawSpecSchema as S
import qualified LawSpecDataStrategies as G

assert :: String -> Bool -> IO ()
assert label condition = unless condition (error label)

right :: Either String a -> a
right = either error id

samples :: Gen a -> [Tree.Tree a]
samples generator = [tree | seed <- [1 .. 60],
  Just tree <- [Internal.evalGen 100 (Seed.from seed) generator]]

forceSample :: Gen LS.Scalar -> IO Int
forceSample generator = evaluate (length (show
  (map Tree.treeValue (take 1 (samples generator)))))

expectError :: String -> Gen LS.Scalar -> IO ()
expectError fragment generator = do
  result <- try (forceSample generator) :: IO (Either SomeException Int)
  case result of
    Left problem -> assert (displayException problem)
      (fragment `isInfixOf` displayException problem)
    Right _ -> error ("expected evaluator failure: " ++ fragment)

nodes :: LS.Scalar -> Int
nodes value = case value of
  LS.SData _ fields -> 1 + sum (map nodes fields)
  LS.SList values -> 1 + sum (map nodes values)
  LS.SPresent _ child -> 1 + maybe 0 nodes child
  _ -> 1

main :: IO ()
main = forM_ [32, 64] $ \bits -> do
  let int = S.Named "Int8" []
      pos = S.Named "Positive" []
      list = S.Named "List" [pos]
      definition = S.Definition "Positive" 0
        [S.Constructor "Positive::Make" [S.Field "value" int]]
      positive _ _ fields _ _ = case fields of
        [LS.SInteger "Int8" n] -> Right (n > 0)
        _ -> Left "bad predicate input"
      schema = right (S.createWithContracts [definition] ["Int8"]
        [("Positive::Make", [positive])])
      scalar _ = Right (LS.SInteger "Int8" <$> Gen.integral (Range.linear (-8) 8))
      generator = right (G.checkedStrategy schema list bits 15 Nothing [] scalar)
      trees = samples generator
      valid value = case S.validateChecked Nothing schema list bits value of
        Right _ -> assert "node budget exceeded" (nodes value <= 15)
        Left problem -> error (show problem)
      fails (LS.SList values) = length values >= 3
      fails _ = False
      minimize tree = do
        valid (Tree.treeValue tree)
        mapM_ (valid . Tree.treeValue) (Tree.treeChildren tree)
        case find (fails . Tree.treeValue) (Tree.treeChildren tree) of
          Nothing -> pure (Tree.treeValue tree)
          Just child -> minimize child
  assert "no checked samples" (not (null trees))
  mapM_ (valid . Tree.treeValue) trees
  failure <- maybe (error "no shrink candidate") pure (find (fails . Tree.treeValue) trees)
  minimal <- minimize failure
  let expected = LS.SList (replicate 3 (LS.SData "Positive::Make" [LS.SInteger "Int8" 1]))
  assert ("bad native shrink: " ++ show minimal) (LS.equal expected minimal)
  -- A finite but exponentially branching rejected subtree must be pruned by
  -- Hedgehog's transformer filter, rather than searched for valid descendants.
  let branching n = if n <= (0 :: Integer) then [] else [n - 1, n - 1]
      branchingScalar _ = Right (LS.SInteger "Int8" <$>
        Gen.shrink branching (pure 28))
      sparse = right (S.createWithContracts [definition] ["Int8"]
        [("Positive::Make", [\_ _ fields _ _ -> Right
          (fields == [LS.SInteger "Int8" 28])])])
      sparseTrees = samples (right
        (G.checkedStrategy sparse pos bits 2 Nothing [] branchingScalar))
  assert "missing sparse shrink root" (not (null sparseTrees))
  pruned <- timeout 2000000 (evaluate (length (Tree.treeChildren (head sparseTrees))))
  assert "rejected shrink subtree was searched instead of pruned" (pruned == Just 0)
  let witness = LS.SData "Positive::Make" [LS.SInteger "Int8" 7]
      seeded = right (G.checkedStrategy schema list bits 7 Nothing [LS.SList (replicate 7 witness)]
        (\_ -> Right (pure (LS.SInteger "Int8" 0))))
      newShape (LS.SList values) = length values > 1
      newShape _ = False
  mapM_ (\tree -> assert "oversized seed escaped budget" (nodes (Tree.treeValue tree) <= 7)) (samples seeded)
  assert "nested witness seeds lost" (any (newShape . Tree.treeValue) (samples seeded))
  assert "invalid witnesses accepted" (case G.checkedStrategy schema pos bits 2 Nothing
    [LS.SData "Positive::Make" [LS.SInteger "Int8" 0]] scalar of Left _ -> True; _ -> False)
  assert "unsafe legacy generator accepted" (case G.strategy schema pos bits 2 scalar of
    Left _ -> True; _ -> False)
  let empty = right (S.createWithContracts [definition] ["Int8"]
        [("Positive::Make", [\_ _ _ _ _ -> Right False])])
      emptyGen = right (G.checkedStrategy empty pos bits 2 Nothing [] scalar)
  assert "empty contract generated values" (null (take 1 (samples emptyGen)))
  let broken = right (S.createWithContracts [definition] ["Int8"]
        [("Positive::Make", [\_ _ _ _ _ -> Left "evaluator marker"])])
  expectError "evaluator marker"
    (right (G.checkedStrategy broken pos bits 2 Nothing [] scalar))
  let first = S.Named "Broken" []
      second = S.Named "Empty" []
      pair = S.Named "Pair" []
      ordered = right (S.createWithContracts
        [ S.Definition "Broken" 0 [S.Constructor "Broken::Make" []]
        , S.Definition "Empty" 0 [S.Constructor "Empty::Make" []]
        , S.Definition "Pair" 0 [S.Constructor "Pair::Make"
            [S.Field "first" first, S.Field "second" second]]
        ] []
        [ ("Broken::Make", [\_ _ _ _ _ -> Left "first field marker"])
        , ("Empty::Make", [\_ _ _ _ _ -> Right False])
        ])
  expectError "first field marker"
    (right (G.checkedStrategy ordered pair bits 3 Nothing [] scalar))
  scope <- LS.newSymbolContext
  other <- LS.newSymbolContext
  let identityType = S.Named "Identity" []
      identitySchema = right (S.createWithContracts
        [S.Definition "Identity" 0 [S.Constructor "Identity::Make"
          [S.Field "value" (S.Named "Symbol" [])]]] ["Symbol"]
        [("Identity::Make", [\_ _ fields _ context -> case fields of
          [value] -> Right (LS.equal value
            (maybe id LS.scopeSymbols context (LS.SSymbol "fixture" "same")))
          _ -> Left "invalid identity"])])
      identity = LS.scopeSymbols scope (LS.SData "Identity::Make" [LS.SSymbol "fixture" "same"])
      symbols _ = Right (pure (LS.SSymbol "other" "same"))
      identities = right (G.checkedStrategy identitySchema identityType bits 2
        (Just scope) [identity] symbols)
  assert "identity samples missing" (not (null (samples identities)))
  forM_ (samples identities) $ \tree ->
    assert "Symbol identity lost" (LS.equal identity (Tree.treeValue tree))
  let scopedGenerator = right (G.checkedStrategy identitySchema identityType bits 2
        (Just scope) [] (\_ -> Right (pure (LS.SSymbol "fixture" "same"))))
  assert "native Symbol generator did not receive scope" (not (null (samples scopedGenerator)))
  forM_ (samples scopedGenerator) $ \tree ->
    assert "native generated identity changed" (LS.equal identity (Tree.treeValue tree))
  assert "foreign scope witness accepted" (case G.checkedStrategy identitySchema identityType bits 2
    (Just other) [identity] symbols of Left _ -> True; _ -> False)
  putStrLn ("Haskell checked strategies and native shrinking passed: " ++ show bits)
