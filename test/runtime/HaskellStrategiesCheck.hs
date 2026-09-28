module HaskellStrategiesCheck (checkStrategies) where

import Control.Monad (forM_, unless)
import Data.List (find)
import Hedgehog (Gen)
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import qualified Hedgehog.Internal.Gen as Internal
import qualified Hedgehog.Internal.Seed as Seed
import qualified Hedgehog.Internal.Tree as Tree
import qualified LawSpecRuntime as LS
import qualified LawSpecSchema as S
import qualified LawSpecDataStrategies as Strategies

check :: Bool -> String -> IO ()
check condition message = unless condition (fail message)

right :: Either String a -> IO a
right = either fail pure

scalar :: String -> Either String (Gen LS.Scalar)
scalar "Bool" = Right (LS.SBool <$> Gen.bool)
scalar "Int8" = Right
  (LS.SInteger "Int8" <$> Gen.integral (Range.linearFrom 0 (-128) 127))
scalar "Unit" = Right (pure (LS.SAbsent "Unit"))
scalar name = Left ("unexpected scalar: " ++ name)

nodes :: LS.Scalar -> Int
nodes value = 1 + sum (map nodes (case value of
  LS.SData _ children -> children
  LS.SList children -> children
  LS.SPresent _ child -> maybe [] pure child
  _ -> []))

sampleTrees :: Gen a -> [Tree.Tree a]
sampleTrees generator =
  [tree | seed <- [1 .. 100],
          Just tree <- [Internal.evalGen 100 (Seed.from seed) generator]]

-- Follow the framework's actual shrink tree, validating candidates even when
-- the property accepts them. No replacement shrinker or random-seed mapping.
minimize :: (LS.Scalar -> IO ()) -> (LS.Scalar -> Bool)
         -> Tree.Tree LS.Scalar -> IO LS.Scalar
minimize validate fails tree = do
  let children = Tree.treeChildren tree
  mapM_ (validate . Tree.treeValue) children
  case find (fails . Tree.treeValue) children of
    Nothing -> pure (Tree.treeValue tree)
    Just child -> minimize validate fails child

checkStrategies :: IO ()
checkStrategies = do
  let named name = S.Named name []
      definition name fields = S.Definition name 0
        [S.Constructor (name ++ "::Make")
          [S.Field (show index) ty | (index, ty) <- zip [0 :: Int ..] fields]]
      deep index = named ("Deep" ++ show index)
      definitions = definition "Deep0" [] :
        [definition ("Deep" ++ show index) [deep (index - 1)] |
         index <- [1 .. 5 :: Int]] ++
        [definition "Uneven" (deep 5 : replicate 9 (named "Bool")),
         S.Definition "Empty" 0 [],
         S.Definition "Tree" 1
           [S.Constructor "Tree::Leaf" [S.Field "value" (S.Parameter 0)],
            S.Constructor "Tree::Branch"
              [S.Field "children" (S.Named "List"
                [S.Named "Tree" [S.Parameter 0]])]]]
  schema <- right (S.create definitions ["Bool", "Int8", "Unit"])
  forM_ [32, 64] $ \bits -> do
    forM_ LS.primitives $ \primitive -> do
      let name = LS.primitiveName primitive
      generator <- right (Strategies.primitiveStrategy bits name)
      forM_ (sampleTrees generator) $ \tree -> do
        _ <- right (LS.validateScalar bits (Tree.treeValue tree))
        forM_ (take 100 (Tree.treeChildren tree)) $ \child -> do
          _ <- right (LS.validateScalar bits (Tree.treeValue child))
          pure ()
    let build ty budget = Strategies.strategy schema ty bits budget scalar
        valid ty budget value = do
          _ <- right (S.validate schema ty bits value)
          check (nodes value <= budget) "structural node budget exceeded"
        rejected result = case result of
          Left _ -> pure ()
          Right _ -> fail "expected empty-domain or budget failure"
    rejected (build (named "Uneven") 15)
    uneven <- right (build (named "Uneven") 16)
    forM_ (sampleTrees uneven) $ \tree -> do
      valid (named "Uneven") 16 (Tree.treeValue tree)
      check (nodes (Tree.treeValue tree) == 16) "uneven product cost"
    let deepList = S.Named "List" [deep 5]
    singletons <- right (build deepList 7)
    let samples = map Tree.treeValue (sampleTrees singletons)
    mapM_ (valid deepList 7) samples
    check (any ((== 7) . nodes) samples) "deep singleton excluded"
    rejected (build (named "Empty") 16)
    forM_ ["List", "Maybe", "Nullable", "Optional"] $ \name -> do
      let ty = S.Named name [named "Empty"]
      rejected (build ty 0)
      generator <- right (build ty 1)
      mapM_ (valid ty 1 . Tree.treeValue) (sampleTrees generator)
    let eitherType = S.Named "Either" [named "Empty", named "Unit"]
    rejected (build eitherType 1)
    eitherGen <- right (build eitherType 2)
    mapM_ (valid eitherType 2 . Tree.treeValue) (sampleTrees eitherGen)
    let listType = S.Named "List" [named "Unit"]
        tooLong (LS.SList values) = length values > 4
        tooLong _ = False
    lists <- right (build listType 10)
    long <- maybe (fail "long lists excluded") pure
      (find (tooLong . Tree.treeValue) (sampleTrees lists))
    minimumList <- minimize (valid listType 10) tooLong long
    check (nodes minimumList == 6) "list did not shrink to five elements"
    let treeType = S.Named "Tree" [named "Int8"]
        positive (LS.SData "Tree::Leaf" [LS.SInteger _ value]) = value > 0
        positive (LS.SData "Tree::Branch" [LS.SList values]) = any positive values
        positive _ = False
    trees <- right (build treeType 24)
    let samples' = sampleTrees trees
    mapM_ (valid treeType 24 . Tree.treeValue) samples'
    failing <- maybe (fail "positive recursive trees excluded") pure
      (find (positive . Tree.treeValue) samples')
    minimumTree <- minimize (valid treeType 24) positive failing
    check (LS.equal minimumTree (LS.SData "Tree::Leaf" [LS.SInteger "Int8" 1]))
      "recursive tree did not shrink to Leaf 1"
  putStrLn "Haskell native generation, budgets, and shrinking passed"
