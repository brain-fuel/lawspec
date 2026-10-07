-- | Indexed families: elaboration, index proofs and index arithmetic.
module IndexedSpec (test_indexedFamiliesElaborateToErasedDataWithProvedIndices) where

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
import LawSpec.Core.Evidence
import LawSpec.IndexTerm

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

-- | Requirements of the planned Core property with this law name.
plansFor :: String -> Either [Diagnostic] [GeneratorRequirement]
plansFor law = do
  plan <- compileCore 64 defaultGeneration [Source "vectors.lawspec" vectors] >>= planTesting
  pure (concat [generatorRequirements p | u <- plannedUnits plan, p <- plannedProperties u,
                C.propertyName (plannedProperty p) == law])

-- | An index is evidence about a value, so it must be erased from generated
-- data, direct generation, and be proved for every definition result rather
-- than trusted. ref:DEC-indexed-families-as-evidence ref:REQ-indexed-families
test_indexedFamiliesElaborateToErasedDataWithProvedIndices :: Spec
test_indexedFamiliesElaborateToErasedDataWithProvedIndices = indexedSpec >> proofSpec >> arithmeticSpec

indexedSpec :: Spec
indexedSpec = describe "natural-indexed families" $ do
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
            expected = [(C.Id (vec ++ "Nil"), ["c0"]), (C.Id (vec ++ "Cons"), ["+ f1 c1"])]
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
    it "requires a literal base or exponent for powers" $
      rejects "may raise only a literal base or to a literal exponent"
        (family ["  | Nil where n = 0", "  | Cons head :: a tail :: Vec m a where n = m ^ m"])
    it "rejects equations for names that are not indices" $
      rejects "k is not an index of Vec" (family ["  | Nil where n = 0, k = 1"])
    it "rejects duplicate index equations" $
      rejects "duplicate index equation" (family ["  | Nil where n = 0, n = 1"])
    it "rejects index expressions in field types" $
      rejects "must use an index variable"
        (family ["  | Nil where n = 0", "  | Cons head :: a tail :: Vec (m + 1) a where n = m"])
    it "requires implicit indices to appear in an invertible pattern first" $
      rejects "must first appear as v, v + k or k * v" (vectors ++
        "law `late` is definition is `for all` (xs :: Vec (k * k) Int8) . nOfVec xs = k * k end end\n")
    it "rejects unbound indices in results" $
      rejects "must be bound by an argument" (vectors ++ "make :: (x :: Int8) -> (r :: Vec k Int8)\n")
    it "rejects negative explicit indices" $
      isLeft (compileVectors (vectors ++
        "law `negative` is definition is `for all` (xs :: Vec (0 - 1) Int8) . true end end\n"))
        `shouldBe` True

proofHeader :: String
proofHeader = unlines
  [ "unit example.proofs"
  , "type Vec (n :: Natural) (a :: Type) is"
  , "  | VNil where n = 0"
  , "  | VCons head :: a tail :: Vec m a where n = m + 1"
  , "end"
  , "type Tree (n :: Natural) (a :: Type) is"
  , "  | Tip where n = 0"
  , "  | Bin left :: Tree l a value :: a right :: Tree r a where n = l + r + 1"
  , "end"
  , "definition concat (xs :: Vec n Int8) (ys :: Vec m Int8) :: Vec (n + m) Int8 is"
  , "  match xs with | VNil -> ys | VCons h t -> VCons h (concat t ys) end"
  , "end"
  ]

coreFor :: String -> Either [Diagnostic] C.Program
coreFor source = compileCore 64 defaultGeneration [Source "proofs.lawspec" (proofHeader ++ source)]

proofSpec :: Spec
proofSpec = describe "proof-producing index layer" $ do
  it "proves definition result indices by unfolding and structural induction" $
    mapM_ (\source -> coreFor source `shouldSatisfy` either (const False) (const True))
      [ "definition single (x :: Int8) :: Vec 1 Int8 is VCons x VNil end"
      , "definition push (x :: Int8) (xs :: Vec n Int8) :: Vec (n + 1) Int8 is VCons x xs end"
      , "definition copy (xs :: Vec n Int8) :: Vec n Int8 is match xs with | VNil -> VNil | VCons h t -> VCons h (copy t) end end"
      , "definition flat (tree :: Tree n Int8) :: Vec n Int8 is match tree with | Tip -> VNil | Bin l v r -> concat (flat l) (VCons v (flat r)) end end" ]
  it "rejects definitions whose results have the wrong index" $
    mapM_ (\source -> case coreFor source of
        Left diagnostics -> concatMap show diagnostics `shouldSatisfy` isInfixOf "could not be proved"
        Right _ -> expectationFailure ("accepted: " ++ source))
      [ "definition bad (xs :: Vec n Int8) :: Vec (n + 1) Int8 is xs end"
      , "definition bad (x :: Int8) :: Vec 2 Int8 is VCons x VNil end"
      , "definition bad (xs :: Vec n Int8) (ys :: Vec m Int8) :: Vec (n + m) Int8 is match xs with | VNil -> ys | VCons h t -> VCons h (bad t t) end end"
      , "definition bad (xs :: Vec n Int8) (ys :: Vec m Int8) :: Vec (n + m) Int8 is match xs with | VNil -> ys | VCons h t -> bad t ys end end"
      , "definition bad (xs :: Vec n Int8) :: Vec n Int8 is match xs with | VNil -> VNil | VCons h t -> VCons h (VCons h t) end end" ]
  it "records proved definition results and runtime-checked adapter contracts" $
    case coreFor "native :: (xs :: Vec n Int8) -> (r :: Vec (n + 1) Int8)\n" of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        let statuses name = [(obligationStage o,obligationStatus o) | o <- programEvidence program,
              obligationStage o `elem` ["precondition", "postcondition"],
              ("::" ++ name) `isSuffixOf'` C.idText (obligationDeclaration o)]
            isSuffixOf' suffix text = reverse suffix == take (length suffix) (reverse text)
        statuses "concat" `shouldSatisfy` (\found -> not (null found) && all ((== Proved) . snd) found)
        statuses "native" `shouldSatisfy` (\found -> not (null found) && all ((== RuntimeChecked) . snd) found)

arithmetic :: String
arithmetic = unlines
  [ "unit example.sums"
  , "type Row (n :: Natural) is"
  , "  | End where n = 0"
  , "  | Cell head :: Int8 tail :: Row m where n = m + 1"
  , "end"
  , "type Perfect (n :: Natural) is"
  , "  | Leaf value :: Int8 where n = 0"
  , "  | Node left :: Perfect m right :: Perfect m where n = m + 1"
  , "end"
  , "type Grid (n :: Natural) is | Grid rows :: Row r columns :: Row c where n = r * c end"
  , "type Halves (n :: Natural) is | Halves front :: Row m back :: Row m where n = m + m end"
  , "type Rest (n :: Natural) is | Rest items :: Row m where n = m - 1 end"
  , "type Bits (n :: Natural) is | Bits items :: Row m where n = 2 ^ m end"
  , "type Pairs (n :: Natural) is | Pairs items :: Row m where n = m div 2 + m mod 2 end"
  ]

arithmeticCore :: String -> Either [Diagnostic] C.Program
arithmeticCore extra = compileCore 64 defaultGeneration [Source "sums.lawspec" (arithmetic ++ extra)]

-- | The index table of one declared family, by constructor name.
indexTable :: C.Program -> String -> [(String, ConstructorIndex)]
indexTable program family =
  [ (reverse (takeWhile (/= ':') (reverse tag)), c)
  | d <- C.programDataDeclarations program, C.dataName d == family
  , Just index <- [C.dataIndex d], (tag, c) <- familyIndexConstructors index ]

arithmeticSpec :: Spec
arithmeticSpec = describe "index arithmetic and sibling indices" $ do
  it "elaborates natural operators, shared variables and subtraction guards into index tables" $
    case arithmeticCore "" of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        let texts family = [(tag, constructorIndexTexts c) | (tag, c) <- indexTable program family]
        texts "Grid" `shouldBe` [("Grid", ["* f0 f1"])]
        -- A variable bound by two fields reads the first and guards the second.
        texts "Halves" `shouldBe` [("Halves", ["+ f0 f0", "== f0 f1"])]
        texts "Perfect" `shouldBe` [("Leaf", ["c0"]), ("Node", ["+ f0 c1", "== f0 f1"])]
        texts "Rest" `shouldBe` [("Rest", ["- f0 c1", ">= f0 c1"])]
        texts "Bits" `shouldBe` [("Bits", ["^ c2 f0"])]
        texts "Pairs" `shouldBe` [("Pairs", ["+ div f0 c2 mod f0 c2", ">= c2 c1", ">= c2 c1"])]
  it "evaluates index terms with natural semantics" $ do
    let field values position index = lookup (position, index) values
        term = IndexApply IndexSubtract (IndexField 0 0) (IndexConstant 1)
    evaluateIndex (field [((0, 0), 3)]) term `shouldBe` Just 2
    evaluateIndex (field [((0, 0), 0)]) term `shouldBe` Nothing
    evaluateIndex (field []) (IndexApply IndexQuotient (IndexConstant 7) (IndexConstant 0)) `shouldBe` Nothing
  it "inverts v + k and k * v when an index first appears in a binder" $ do
    arithmeticCore "dropFirst :: (xs :: Row (k + 1)) -> (r :: Rest k)\n" `shouldSatisfy` either (const False) (const True)
    arithmeticCore "halve :: (xs :: Row (2 * k)) -> (r :: Row k)\n" `shouldSatisfy` either (const False) (const True)
  it "rejects values that break an index guard" $ do
    let example value = unlines
          [ "law `balanced` is definition is `for all` (t :: Perfect 1) . true end"
          , "  example `given` is t = " ++ value ++ " expect nOfPerfect t = 1 end end" ]
    arithmeticCore (example "Node (Leaf 1) (Leaf 2)") `shouldSatisfy` either (const False) (const True)
    arithmeticCore (example "Node (Leaf 1) (Node (Leaf 2) (Leaf 3))") `shouldSatisfy` isLeft
  it "proves sibling and product indices, and defers non-linear claims to runtime" $ do
    let status program name = [obligationStatus o | o <- programEvidence program,
          obligationStage o == "postcondition", C.idText (obligationDeclaration o) == "example.sums::" ++ name]
        source = unlines
          [ "definition mirrorP (t :: Perfect n) :: Perfect n is"
          , "  match t with | Leaf v -> Leaf v | Node l r -> Node (mirrorP r) (mirrorP l) end"
          , "end"
          , "definition transposeG (g :: Grid n) :: Grid n is match g with | Grid r c -> Grid c r end end"
          , "definition widen (g :: Grid n) :: Grid (n + n) is match g with | Grid r c -> Grid r (Cell 0 c) end end" ]
    case arithmeticCore source of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        status program "mirrorP" `shouldBe` [Proved, Proved]
        status program "transposeG" `shouldBe` [Proved, Proved]
        status program "widen" `shouldBe` [Proved, RuntimeChecked]
  it "proves index guards at construction inside checked definitions" $ do
    arithmeticCore "definition graft (t :: Perfect n) (u :: Perfect n) :: Perfect (n + 1) is Node t u end\n"
      `shouldSatisfy` either (const False) (const True)
    case arithmeticCore "definition skew (t :: Perfect n) :: Perfect (n + 1) is Node t (Leaf 0) end\n" of
      Left diagnostics -> concatMap show diagnostics `shouldSatisfy` isInfixOf "constructor index guard could not be proved"
      Right _ -> expectationFailure "accepted an unbalanced construction"
  it "directs generation for guarded families without an index claim" $
    case arithmeticCore "mirror :: (t :: Perfect n) -> (r :: Perfect n)\n" >>= planTesting of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right plan -> do
        let indexed = [g | u <- plannedUnits plan, p <- plannedProperties u, Just g <- map generatorIndex (generatorRequirements p)]
        map indexedEquations indexed `shouldSatisfy` any (any ((== ["+ f0 c1", "== f0 f1"]) . snd))
