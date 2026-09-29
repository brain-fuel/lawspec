module IndexedSpec (spec) where

import Data.Either (isLeft)
import Data.List (isInfixOf)
import Data.Maybe (isJust, mapMaybe)
import Test.Hspec
import qualified LawSpec.Core as C
import LawSpec.Compile
import LawSpec.Emit
import LawSpec.Frontend (compileCore)
import LawSpec.Model hiding (Expectation)
import LawSpec.Testing

vectors :: String
vectors = unlines
  [ "unit example.vectors"
  , "type Vec (n :: Natural) (a :: Type) is"
  , "  | Nil where n = 0"
  , "  | Cons head :: a tail :: Vec m a where n = m + 1"
  , "end"
  , "replicate :: (n :: Natural where n < 64) -> (x :: Int8) -> (r :: Vec n Int8)"
  , "append :: (xs :: Vec n Int8) -> (ys :: Vec m Int8) -> (r :: Vec (n + m) Int8)"
  , "zip :: (xs :: Vec n Int8) -> (ys :: Vec n Bool) -> (r :: Vec n Bool)"
  , "law `append lengths add` is definition is"
  , "  `for all` (xs :: Vec n Int8) (ys :: Vec m Int8) . nOfVec (append xs ys) = n + m"
  , "end end"
  , "law `fixed length` is definition is"
  , "  `for all` (xs :: Vec 3 Int8) . nOfVec xs = 3"
  , "end end"
  , "law `shared length` is definition is"
  , "  `for all` (xs :: Vec n Int8) (ys :: Vec n Bool) . nOfVec (zip xs ys) = n"
  , "end end"
  ]

compileVectors :: String -> Either [Diagnostic] ([Unit], [Expanded])
compileVectors source = compile [Source "vectors.lawspec" source]

rejects :: String -> String -> Expectation
rejects fragment source = case compileVectors source of
  Left diagnostics -> concatMap show diagnostics `shouldSatisfy` isInfixOf fragment
  Right _ -> expectationFailure ("expected rejection mentioning " ++ show fragment)

family :: [String] -> String
family constructors = unlines
  (["unit example.bad", "type Vec (n :: Natural) (a :: Type) is"] ++ constructors ++ ["end"])

-- Requirements of the planned Core property with this law name.
plansFor :: String -> Either [Diagnostic] [GeneratorRequirement]
plansFor law = do
  plan <- compileCore 64 defaultGeneration [Source "vectors.lawspec" vectors] >>= planTesting
  pure (concat [generatorRequirements p | u <- plannedUnits plan, p <- plannedProperties u,
                C.propertyName (plannedProperty p) == law])

spec :: Spec
spec = describe "natural-indexed families" $ do
  it "elaborates to erased data, a structural measure and a named refinement" $
    case compileVectors vectors of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right (units, _) -> do
        let u = head units
        map dataTypeName (dataTypes u) `shouldContain` ["Vec"]
        [dataTypeParameters d | d <- dataTypes u, dataTypeName d == "Vec"] `shouldBe` [["a"]]
        -- Generic measures are specialized per concrete use.
        map functionName (functionDefinitions u) `shouldSatisfy` any (isInfixOf "nOfVec")
        map refinementName (refinements u) `shouldContain` ["Natural", "Vec@index"]

  it "binds implicit indices to the measure of the first binder" $
    case plansFor "append lengths add" of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right plans -> do
        length plans `shouldBe` 2
        -- Free indices are determined by generated values, not constrained.
        mapMaybe generatorIndex plans `shouldBe` []

  it "directs generation for fixed and shared indices by the constructor equations" $
    case (,) <$> plansFor "fixed length" <*> plansFor "shared length" of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right (fixed, shared) -> do
        let equations = map indexedEquations . mapMaybe generatorIndex
            vec = "example.vectors::type::Vec::"
            expected = [(C.Id (vec ++ "Nil"), 0, []), (C.Id (vec ++ "Cons"), 1, [1])]
        equations fixed `shouldBe` [expected]
        map (isJust . generatorIndex) shared `shouldBe` [False, True]
        equations shared `shouldBe` [expected]

  it "keeps ordinary data declarations unchanged" $
    case compileVectors "unit plain\ntype Pair (a :: Type) is Pair first :: a second :: a end\n" of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right (units, _) -> map refinementName (refinements (head units)) `shouldBe` []

  it "emits index-directed generators for all eight targets" $
    case compileVectors vectors of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right (units, expanded) -> mapM_ (\(target, call) -> case emit target units expanded of
        Left diagnostics -> expectationFailure (target ++ ": " ++ show diagnostics)
        Right files -> concatMap artifactContent files `shouldSatisfy` isInfixOf call)
        [ ("python", "index=("), ("javascript", "example.vectors::type::Vec::Cons")
        , ("typescript", "example.vectors::type::Vec::Cons"), ("java", "indexedGenerator")
        , ("kotlin", "indexedGenerator"), ("go", "lsIndexedDataStrategy")
        , ("haskell", "Strategies.indexedStrategy"), ("rust", "ls_gen::indexed_strategy") ]

  describe "diagnostics" $ do
    it "requires an equation for every index" $
      rejects "missing index equation for n" (family ["  | Nil", "  | Cons head :: a tail :: Vec m a where n = m + 1"])
    it "requires index variables to be bound by fields of indexed type" $
      rejects "index variable k is not bound" (family ["  | Nil where n = 0", "  | Cons head :: a where n = k + 1"])
    it "requires linear index expressions" $
      rejects "sum of natural literals and index variables"
        (family ["  | Nil where n = 0", "  | Cons head :: a tail :: Vec m a where n = m * 2"])
    it "rejects equations for names that are not indices" $
      rejects "a is not an index of Vec" (family ["  | Nil where n = 0, a = 1"])
    it "rejects duplicate index equations" $
      rejects "duplicate index equation" (family ["  | Nil where n = 0, n = 1"])
    it "rejects index expressions in field types" $
      rejects "must use an index variable"
        (family ["  | Nil where n = 0", "  | Cons head :: a tail :: Vec (m + 1) a where n = m"])
    it "requires implicit indices to appear alone first" $
      rejects "must first appear alone" (vectors ++
        "law `late` is definition is `for all` (xs :: Vec (k + 1) Int8) . nOfVec xs = k + 1 end end\n")
    it "rejects unbound indices in results" $
      rejects "must be bound by an argument" (vectors ++ "make :: (x :: Int8) -> (r :: Vec k Int8)\n")
    it "rejects negative explicit indices" $
      isLeft (compileVectors (vectors ++
        "law `negative` is definition is `for all` (xs :: Vec (0 - 1) Int8) . true end end\n"))
        `shouldBe` True
