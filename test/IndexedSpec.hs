-- | Indexed families: elaboration, index proofs and index arithmetic.
module IndexedSpec (test_indexedFamiliesElaborateToErasedDataWithProvedIndices) where

import FixtureSource (extendUnit)
import Data.Either (isLeft)
import Data.List (isInfixOf)
import Data.Maybe (isJust, mapMaybe)
import Test.Hspec
import qualified LawSpec.Core as C
import LawSpec.Compile
import LawSpec.CoreEmit (emitPlan, targets)
import LawSpec.Emit
import LawSpec.Frontend (compileCore,compileCoreCanonical)
import qualified LawSpec.Core.Types as CoreTypes
import qualified LawSpec.Core.Definitions as CoreDefinitions
import qualified LawSpec.Core.Eval as CoreEval
import LawSpec.Core.Value (Value(..))
import LawSpec.Model hiding (Expectation)
import LawSpec.Testing
import LawSpec.Core.Evidence
import LawSpec.IndexTerm

vectors :: String
vectors = unlines
  [ "unit example.vectors"
   ++ "\n", ""
  , "type Vec (n :: Whole) (a :: Type) is one of"
  , "  | Nil where n = 0"
  , "  | Cons of type record{ head :: a tail :: Vec m a} where n = m + 1"
  , "end type"
  , "replicate :: (n :: Whole where n < 64) -> (x :: Int8) -> (r :: Vec n Int8)"
  , "append :: (xs :: Vec n Int8) -> (ys :: Vec m Int8) -> (r :: Vec (n + m) Int8)"
  , "zip :: (xs :: Vec n Int8) -> (ys :: Vec n Bool) -> (r :: Vec n Bool)"
  , "law \"|append lengths add| is definition :"
  , "for all (xs :: Vec n Int8) (ys :: Vec m Int8) => nOfVec (append xs ys) = n + m end for all"
  , "end definition end law"
  , "law \"|fixed length| is definition :"
  , "for all (xs :: Vec 3 Int8) => nOfVec xs = 3 end for all"
  , "end definition end law"
  , "law \"|shared length| is definition :"
  , "for all (xs :: Vec n Int8) (ys :: Vec n Bool) => nOfVec (zip xs ys) = n end for all"
  , "end definition end law"
  , "\nend unit" ]

compileVectors :: String -> Either [Diagnostic] ([Unit], [Expanded])
compileVectors source = compile [Source "vectors.lawspec" source]

rejects :: String -> String -> Expectation
rejects fragment source = case compileVectors source of
  Left diagnostics -> concatMap show diagnostics `shouldSatisfy` isInfixOf fragment
  Right _ -> expectationFailure ("expected rejection mentioning " ++ show fragment)

family :: [String] -> String
family constructors = unlines
  (["unit example.bad", "type Vec (n :: Whole) (a :: Type) is one of"] ++ constructors ++ ["end type", "end unit"])

-- | Requirements of the planned Core property with this law name.
plansFor :: String -> Either [Diagnostic] [GeneratorRequirement]
plansFor law = do
  plan <- compileCore 64 defaultGeneration [Source "vectors.lawspec" vectors] >>= planTesting
  pure (concat [generatorRequirements p | u <- plannedUnits plan, p <- plannedProperties u,
                C.propertyName (plannedProperty p) == "\"|" ++ law ++ "|"])

-- | An index is evidence about a value, so it must be erased from generated
-- data, direct generation, and be proved for every definition result rather
-- than trusted. ref:DEC-indexed-families-as-evidence ref:REQ-indexed-families
test_indexedFamiliesElaborateToErasedDataWithProvedIndices :: Spec
test_indexedFamiliesElaborateToErasedDataWithProvedIndices = indexedSpec >> proofSpec >> arithmeticSpec >> recordSpec

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

  it "retains fixed and shared index predicates for record payload generation" $
    case (,) <$> plansFor "fixed length" <*> plansFor "shared length" of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right (fixed, shared) -> do
        length fixed `shouldBe` 1
        length shared `shouldBe` 2
        map generatorIndex (fixed ++ shared) `shouldBe` replicate 3 Nothing
        map (null . generatorPredicates) fixed `shouldBe` [False]
        case shared of
          [first, second] -> concatMap C.freeBinders (generatorPredicates second)
            `shouldContain` [C.binderId (generatorBinder first)]
          _ -> expectationFailure "missing shared index input"

  it "keeps ordinary data declarations unchanged" $
    case compileVectors "unit plain\n\ntype Pair (a :: Type) is a record{  first :: a second :: a} end type\nend unit\n" of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right (units, _) -> map refinementName (refinements (head units)) `shouldBe` []

  it "emits record payload index paths and checked predicates on every target" $
    case compileVectors vectors of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right (units, expanded) -> mapM_ (\target -> case emit target units expanded of
        Left diagnostics -> expectationFailure (target ++ ": " ++ show diagnostics)
        Right files -> concatMap artifactContent files `shouldSatisfy` isInfixOf "p0/1.0") targets

  it "retains direct index generation for a single explicitly typed payload" $ do
    let body = unlines
          [ "unit example.directIndex"
          , "type Count (n :: Whole) is one of | Zero where n = 0 | Next of type Count m where n = m + 1 end type"
          , "law fixed is definition: for all (value :: Count 3) => nOfCount value = 3 end for all end definition end law"
          , "end unit" ]
    case compileCore 64 defaultGeneration [Source "direct.lawspec" body] >>= planTesting of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right plan -> do
        let requirements = [r | u <- plannedUnits plan, p <- plannedProperties u, r <- generatorRequirements p]
        map (fmap indexedEquations . generatorIndex) requirements `shouldBe`
          [Just [(C.Id "example.directIndex::type::Count::Zero", ["c0"]),
                 (C.Id "example.directIndex::type::Count::Next", ["+ f0 c1"])]]
        mapM_ (\target -> emitPlan target plan `shouldSatisfy` either (const False) (const True)) targets

  it "expands indexed strategy aliases and checks nested bind domains on every target" $ do
    let source = extendUnit vectors $ unlines
          [ "harness example.vectors.testing for example.vectors is"
          , "  strategy singleton :: Vec 1 Int8 is one of Cons record{head = 7, tail = Nil} end strategy"
          , "  strategy alias :: Vec 1 Int8 is singleton end strategy"
          , "  strategy three :: Vec 3 Int8 is"
          , "    bind tail :: Vec 1 Int8 from alias in"
          , "    one of Cons record{head = 1, tail = Cons record{head = 2, tail = tail}}"
          , "    end bind"
          , "  end strategy"
          , "  for law \"|fixed length| use three for xs end for law"
          , "end harness" ]
    case compileCore 64 defaultGeneration [Source "strategies.lawspec" source] >>= planTesting of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right plan -> do
        let draws = [draw | unit <- plannedUnits plan, property <- plannedProperties unit,
              (_,_,draw) <- C.harnessDraws (C.propertyHarness (plannedProperty property))]
        case draws of
          [C.DrawSuchThat (C.DrawBind _ (C.DrawSuchThat (C.DrawSuchThat _ _ _ _) _ _ _) _) _ _ _] -> pure ()
          other -> expectationFailure ("missing strategy or bind index predicate: " ++ show other)
        mapM_ (\target -> emitPlan target plan `shouldSatisfy` either (const False) (const True)) targets

  describe "diagnostics" $ do
    it "requires an equation for every index" $
      rejects "missing index equation for n" (family ["  | Nil", "  | Cons of type record{head :: a tail :: Vec m a} where n = m + 1"])
    it "requires index variables to be bound by fields of indexed type" $
      rejects "index variable k is not bound" (family ["  | Nil where n = 0", "  | Cons of type a where n = k + 1"])
    it "requires a literal base or exponent for powers" $
      rejects "may raise only a literal base or to a literal exponent"
        (family ["  | Nil where n = 0", "  | Cons of type record{head :: a tail :: Vec m a} where n = m ^ m"])
    it "rejects equations for names that are not indices" $
      rejects "k is not an index of Vec" (family ["  | Nil where n = 0, k = 1"])
    it "rejects duplicate index equations" $
      rejects "duplicate index equation" (family ["  | Nil where n = 0, n = 1"])
    it "rejects index expressions in field types" $
      rejects "must use an index variable"
        (family ["  | Nil where n = 0", "  | Cons of type record{head :: a tail :: Vec (m + 1) a} where n = m"])
    it "requires implicit indices to appear in an invertible pattern first" $
      rejects "must first appear as v, v + k or k * v" (extendUnit vectors $ "law late is definition: for all (xs :: Vec (k * k) Int8) => nOfVec xs = k * k end for all end definition end law\n")
    it "rejects unbound indices in results" $
      rejects "must be bound by an argument" (extendUnit vectors $ "make :: (x :: Int8) -> (r :: Vec k Int8)\n")
    it "rejects negative explicit indices" $
      isLeft (compileVectors (extendUnit vectors $ "law negative is definition: for all (xs :: Vec (0 - 1) Int8) => true end for all end definition end law\n"))
        `shouldBe` True

proofHeader :: String
proofHeader = unlines
  [ "unit example.proofs"
   ++ "\n", ""
  , "type Vec (n :: Whole) (a :: Type) is one of"
  , "  | VNil where n = 0"
  , "  | VCons of type record{ head :: a tail :: Vec m a} where n = m + 1"
  , "end type"
  , "type Tree (n :: Whole) (a :: Type) is one of"
  , "  | Tip where n = 0"
  , "  | Bin of type record{ left :: Tree l a value :: a right :: Tree r a} where n = l + r + 1"
  , "end type"
  , "function concat (xs :: Vec n Int8) (ys :: Vec m Int8) -> Vec (n + m) Int8 is"
  , "  first matching case of xs : when VNil then ys when VCons record{ head = h , tail = t} then VCons record{ head = h , tail = (concat t ys)} end case"
  , "end function"
  , "\nend unit" ]

coreFor :: String -> Either [Diagnostic] C.Program
coreFor source = compileCore 64 defaultGeneration [Source "proofs.lawspec" (extendUnit proofHeader $ source)]

proofSpec :: Spec
proofSpec = describe "proof-producing index layer" $ do
  it "proves definition result indices by unfolding and structural induction" $
    mapM_ (\source -> coreFor source `shouldSatisfy` either (const False) (const True))
      [ "function single (x :: Int8) -> Vec 1 Int8 is VCons record{head = x, tail = VNil} end function"
      , "function push (x :: Int8) (xs :: Vec n Int8) -> Vec (n + 1) Int8 is VCons record{head = x, tail = xs} end function"
      , "function copy (xs :: Vec n Int8) -> Vec n Int8 is first matching case of xs: when VNil then VNil when VCons record{head = h, tail = t} then VCons record{head = h, tail = copy t} end case end function"
      , "function flat (tree :: Tree n Int8) -> Vec n Int8 is first matching case of tree: when Tip then VNil when Bin record{left = l, value = v, right = r} then concat (flat l) (VCons record{head = v, tail = flat r}) end case end function" ]
  it "rejects definitions whose results have the wrong index" $
    mapM_ (\source -> case coreFor source of
        Left diagnostics -> concatMap show diagnostics `shouldSatisfy` isInfixOf "could not be proved"
        Right _ -> expectationFailure ("accepted: " ++ source))
      [ "function bad (xs :: Vec n Int8) -> Vec (n + 1) Int8 is xs end function"
      , "function bad (x :: Int8) -> Vec 2 Int8 is VCons record{head = x, tail = VNil} end function"
      , "function bad (xs :: Vec n Int8) (ys :: Vec m Int8) -> Vec (n + m) Int8 is first matching case of xs: when VNil then ys when VCons record{head = h, tail = t} then VCons record{head = h, tail = bad t t} end case end function"
      , "function bad (xs :: Vec n Int8) (ys :: Vec m Int8) -> Vec (n + m) Int8 is first matching case of xs: when VNil then ys when VCons record{head = h, tail = t} then bad t ys end case end function"
      , "function bad (xs :: Vec n Int8) -> Vec n Int8 is first matching case of xs: when VNil then VNil when VCons record{head = h, tail = t} then VCons record{head = h, tail = VCons record{head = h, tail = t}} end case end function" ]
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
   ++ "\n", ""
  , "type Row (n :: Whole) is one of"
  , "  | End where n = 0"
  , "  | Cell of type record{ head :: Int8 tail :: Row m} where n = m + 1"
  , "end type"
  , "type Perfect (n :: Whole) is one of"
  , "  | Leaf  of type Int8 where n = 0"
  , "  | Node of type record{ left :: Perfect m right :: Perfect m} where n = m + 1"
  , "end type"
  , "type Grid (n :: Whole) is one of | Grid of type record{ rows :: Row r columns :: Row c} where n = r * c end type"
  , "type Halves (n :: Whole) is one of | Halves of type record{ front :: Row m back :: Row m} where n = m + m end type"
  , "type Rest (n :: Whole) is one of | Rest  of type Row m where n = m - 1 end type"
  , "type Bits (n :: Whole) is one of | Bits  of type Row m where n = 2 ^ m end type"
  , "type Pairs (n :: Whole) is one of | Pairs  of type Row m where n = m div 2 + m mod 2 end type"
  , "\nend unit" ]

arithmeticCore :: String -> Either [Diagnostic] C.Program
arithmeticCore extra = compileCore 64 defaultGeneration [Source "sums.lawspec" (extendUnit arithmetic $ extra)]

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
        texts "Grid" `shouldBe` [("Grid", ["* p0/1.0 p0/0.0"])]
        -- A variable bound by two fields reads the first and guards the second.
        texts "Halves" `shouldBe` [("Halves", ["+ p0/0.0 p0/0.0", "== p0/0.0 p0/1.0"])]
        texts "Perfect" `shouldBe` [("Leaf", ["c0"]), ("Node", ["+ p0/0.0 c1", "== p0/0.0 p0/1.0"])]
        texts "Rest" `shouldBe` [("Rest", ["- f0 c1", ">= f0 c1"])]
        texts "Bits" `shouldBe` [("Bits", ["^ c2 f0"])]
        texts "Pairs" `shouldBe` [("Pairs", ["+ div f0 c2 mod f0 c2", ">= c2 c1", ">= c2 c1"])]
  it "keeps nested paths distinct from direct field and index positions" $ do
    let term = IndexApply IndexSubtract (IndexPath [0,2,1] 1) (IndexConstant 2)
        field path index = lookup (path,index) [(([0,2,1],1),5)]
    termFields term `shouldBe` [([0,2,1],1)]
    evaluateIndex field term `shouldBe` Just 3
    evaluateIndex field (IndexField 0 1) `shouldBe` Nothing
    guardHolds field (IndexGuard IndexAtLeast (IndexPath [0,2,1] 1) (IndexConstant 6)) `shouldBe` False
    indexTermText term `shouldBe` "- p0/2/1.1 c2"
  it "evaluates index terms with natural semantics" $ do
    let field values path index = case path of
          [position] -> lookup (position, index) values
          _ -> Nothing
        term = IndexApply IndexSubtract (IndexField 0 0) (IndexConstant 1)
    evaluateIndex (field [((0, 0), 3)]) term `shouldBe` Just 2
    evaluateIndex (field [((0, 0), 0)]) term `shouldBe` Nothing
    evaluateIndex (field []) (IndexApply IndexQuotient (IndexConstant 7) (IndexConstant 0)) `shouldBe` Nothing
  it "inverts v + k and k * v when an index first appears in a binder" $ do
    arithmeticCore "dropFirst :: (xs :: Row (k + 1)) -> (r :: Rest k)\n" `shouldSatisfy` either (const False) (const True)
    arithmeticCore "halve :: (xs :: Row (2 * k)) -> (r :: Row k)\n" `shouldSatisfy` either (const False) (const True)
  it "rejects values that break an index guard" $ do
    let example value = unlines
          [ "law balanced is definition: for all (t :: Perfect 1) => true end for all end definition"
          , "  example givenCase: t = " ++ value ++ " expect nOfPerfect t = 1 end example end law" ]
    arithmeticCore (example "Node record{left = Leaf 1, right = Leaf 2}") `shouldSatisfy` either (const False) (const True)
    arithmeticCore (example "Node record{left = Leaf 1, right = Node record{left = Leaf 2, right = Leaf 3}}") `shouldSatisfy` isLeft
  it "proves sibling and product indices, and defers non-linear claims to runtime" $ do
    let status program name = [obligationStatus o | o <- programEvidence program,
          obligationStage o == "postcondition", C.idText (obligationDeclaration o) == "example.sums::" ++ name]
        source = unlines
          [ "function mirrorP (t :: Perfect n) -> Perfect n is"
          , "first matching case of t : when Leaf v then Leaf v when Node record{left = l, right = r} then Node record{left = mirrorP r, right = mirrorP l} end case"
          , "end function"
          , "function transposeG (g :: Grid n) -> Grid n is first matching case of g: when Grid record{rows = r, columns = c} then Grid record{rows = c, columns = r} end case end function"
          , "function widen (g :: Grid n) -> Grid (n + n) is first matching case of g: when Grid record{rows = r, columns = c} then Grid record{rows = r, columns = Cell record{head = 0, tail = c}} end case end function" ]
    case arithmeticCore source of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        status program "mirrorP" `shouldBe` [Proved, Proved]
        status program "transposeG" `shouldBe` [Proved, Proved]
        status program "widen" `shouldBe` [Proved, RuntimeChecked]
  it "proves index guards at construction inside checked definitions" $ do
    arithmeticCore "function graft (t :: Perfect n) (u :: Perfect n) -> Perfect (n + 1) is Node record{left = t, right = u} end function\n"
      `shouldSatisfy` either (const False) (const True)
    case arithmeticCore "function skew (t :: Perfect n) -> Perfect (n + 1) is Node record{left = t, right = Leaf 0} end function\n" of
      Left diagnostics -> concatMap show diagnostics `shouldSatisfy` isInfixOf "constructor index guard could not be proved"
      Right _ -> expectationFailure "accepted an unbalanced construction"
  it "retains constructor guards during ordinary record payload generation" $
    case arithmeticCore "mirror :: (t :: Perfect n) -> (r :: Perfect n)\n" >>= planTesting of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right plan -> do
        let guards = [constructorIndexTexts c | d <- planDataDeclarations plan,
                      Just index <- [C.dataIndex d], (_,c) <- familyIndexConstructors index]
        guards `shouldContain` [["+ p0/0.0 c1", "== p0/0.0 p0/1.0"]]

-- Intrinsic record relationships cannot be erased when a constructor or a
-- quantified input groups indexed children. ref:DEC-indexed-families-as-evidence
-- ref:DEC-typed-core-boundary ref:DEC-total-definitions
recordSpec :: Spec
recordSpec = describe "indexed source records" $ do
  let compileRecords bits body=compileCoreCanonical bits defaultGeneration [Source "indexed-records.lawspec" ("unit indexed.records\n\n"++body ++ "\nend unit\n")]
      stack=unlines
        [ "type Stack (n of type Whole) is one of"
        , "| Empty where n = 0"
        , "| Push of type record{top of type Int8 rest of type Stack m} where n = m + 1"
        , "end type"
        , "function copyStack (stack of type Stack n) -> Stack n is"
        , "first matching case of stack:"
        , "when Empty then Empty"
        , "when Push payload then Push record{top = payload.top, rest = copyStack payload.rest}"
        , "end case end function"
        , "function push (top of type Int8) (rest of type Stack n) -> Stack (n + 1) is Push record{top = top, rest = rest} end function"
        , "function pop (stack of type Stack (n + 1)) -> Stack n is first matching case of stack: when Push payload then payload.rest end case end function"
        , "law stackResult is definition: pop (copyStack (push 4 Empty)) must be Empty end definition end law" ]
      tree variable reversed=unlines
        ["type Tree (n of type Whole) is one of"
        ,"| Leaf where n = 0"
        ,"| Branch of type record{"++(if reversed then "right of type Tree "++variable++" left of type Tree "++variable else "left of type Tree "++variable++" right of type Tree "++variable)++"} where n = "++variable++" + 1"
        ,"end type"]
      makers=unlines
        ["function branch (left of type Tree n) (right of type Tree n) -> Tree (n + 1) is Branch record{left = left, right = right} end function"
        ,"function copyTree (tree of type Tree n) -> Tree n is"
        ,"first matching case of tree: when Leaf then Leaf when Branch pair then Branch record{left = copyTree pair.left, right = copyTree pair.right} end case end function"
        ,"function paired (pair of type record{left of type Tree m right of type Tree m}) -> Tree (m + 1) is Branch pair end function"
        ,"law treeResult is definition: copyTree (paired record{left = Leaf, right = Leaf}) must be branch Leaf Leaf end definition end law\n"]
      closedProperties bits program=case (CoreTypes.makeRegistry (C.programDataDeclarations program),CoreDefinitions.prepareDefinitions program) of
        (Right registry,Right invoke) -> mapM_ (\property -> CoreEval.evaluateValueProposition registry bits invoke [] (C.propertyBody property) `shouldBe` Right True)
          [property | unit<-C.programUnits program,property<-C.unitProperties unit,null (C.propertyInputs property)]
        (Left message,_) -> expectationFailure message
        (_,Left diagnostics) -> expectationFailure (show diagnostics)
  it "checks nested measures, recursion and dependent results through a single record payload" $
    mapM_ (\bits -> case compileRecords bits stack of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        let texts=[constructorIndexTexts index | (tag,index)<-indexTable program "Stack",tag=="Push"]
        texts `shouldBe` [["+ p0/0.0 c1"]]
        closedProperties bits program) [32,64]
  it "retains shared record indices through construction, recursion and implicit record inputs" $
    mapM_ (\bits -> case compileRecords bits (tree "m" False++makers) of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        let guards=[C.structuralIndexGuards structure | declaration<-C.programDataDeclarations program,
              Just structure<-[C.dataStructural declaration],not (null (C.structuralIndexGuards structure))]
        guards `shouldBe` [[IndexGuard IndexEqual (IndexField 0 0) (IndexField 1 0)]]
        closedProperties bits program) [32,64]
  it "rejects a recursive copy that drops its indexed tail" $ do
    let damaged=unlines [if "when Push payload then Push record{" `isInfixOf` line then
          "when Push payload then Push record{top = payload.top, rest = Empty}" else line | line<-lines stack]
    compileRecords 64 damaged `shouldSatisfy` either (\diagnostics -> any (\d -> code d=="total") diagnostics) (const False)
  it "checks indexed record table inputs and refuses a mismatched row" $ do
    let prefix=unlines
          ["type Level (n of type Whole) is one of | Low where n = 0 | High where n = 1 end type\n"
          ,"function measure (pair of type record{left of type Level m right of type Level m}) -> Whole is nOfLevel pair.left end function"
          ,"law measured is definition: for all (pair of type record{left of type Level m right of type Level m}) => measure pair must be nOfLevel pair.right end for all end definition"
          ,"expect measure pair = expected in table (pair,expected):"]
        good=prefix++"row record{left = Low, right = Low}, 0 row record{left = High, right = High}, 1 end table end law"
        bad=prefix++"row record{left = Low, right = High}, 0 end table end law"
    mapM_ (\bits -> do
      compileRecords bits good `shouldSatisfy` either (const False) (const True)
      compileRecords bits bad `shouldSatisfy` either (const True) (const False)) [32,64]
  it "retains repeated indices in one family field, including beneath a nested product" $ do
    let family=unlines
          ["type Matrix (rows of type Whole) (columns of type Whole) is one of"
          ,"| Zero where rows = 0, columns = 0"
          ,"| Skew where rows = 0, columns = 1"
          ,"| One where rows = 1, columns = 1 end type"]
        body nested=family++"law diagonal is definition: for all (pair of type "++
          (if nested then "record{child of type record{matrix of type Matrix dimension dimension}}" else "record{matrix of type Matrix dimension dimension}")++
          ") => rowsOfMatrix pair."++(if nested then "child." else "")++"matrix must be columnsOfMatrix pair."++
          (if nested then "child." else "")++"matrix end for all end definition end law\n"
    mapM_ (\(bits,nested) -> do
      let maker selected=family++"function make (ignored of type Bool) -> record{matrix of type Matrix dimension dimension} is record{matrix = "++selected++"} end function"
      compileRecords bits (maker "Zero") `shouldSatisfy` either (const False) (const True)
      compileRecords bits (maker "Skew") `shouldSatisfy` either (any ((=="total") . code)) (const False)
      case compileRecords bits (body nested) of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right program -> do
          [C.structuralIndexGuards structure | declaration<-C.programDataDeclarations program,
            Just structure<-[C.dataStructural declaration],not (null (C.structuralIndexGuards structure))]
            `shouldBe` [[IndexGuard IndexEqual (IndexField 0 0) (IndexField 0 1)]]
          case (CoreTypes.makeRegistry (C.programDataDeclarations program),CoreDefinitions.prepareDefinitions program) of
            (Right registry,Right invoke) -> do
              let [property]=[p | u<-C.programUnits program,p<-C.unitProperties u,C.propertyName p=="diagonal"]
                  [quantifier]=C.propertyInputs property
                  binder=C.quantifiedBinder quantifier
              case finiteValuesWithRegistry registry bits 16 (C.binderType binder) of
                Right (Just values) -> do
                  length values `shouldBe` 2
                  mapM_ (\value -> CoreEval.evaluateValueProposition registry bits invoke [(C.binderId binder,value)] (C.propertyBody property) `shouldBe` Right True) values
                other -> expectationFailure (show other)
            _ -> expectationFailure "failed to prepare a repeated-index product") [(bits,nested) | bits<-[32,64],nested<-[False,True]]
  it "gives field order and implicit index spelling no part in structural identity" $ do
    let identity body=fmap (\program -> [C.dataId declaration | declaration<-C.programDataDeclarations program,
          Just structure<-[C.dataStructural declaration],not (null (C.structuralIndexGuards structure))]) (compileRecords 64 body)
    identity (tree "m" False) `shouldBe` identity (tree "dimension" True)
    identity (tree "m" False) `shouldSatisfy` either (const False) (not . null)
  it "rejects unchecked sibling sizes and implicit conversion from an unconstrained product" $ do
    let wrong=tree "m" False++"function wrong (left of type Tree n) (right of type Tree k) -> Tree (n + 1) is Branch record{left = left, right = right} end function"
        cast=tree "m" False++"function wrong (pair of type record{left of type Tree n right of type Tree k}) -> Tree 1 is Branch pair end function"
    mapM_ (\body -> compileRecords 64 body `shouldSatisfy` either (\diagnostics -> any (\d -> "index" `isInfixOf` message d) diagnostics) (const False)) [wrong,cast]
  it "admits explicit branch evidence for record construction and rejects the unguarded mutation" $ do
    let prefix=tree "m" False
        header="function checkedPair (pair of type record{left of type Tree n right of type Tree k}) -> Maybe (Tree 1) is "
        construction="Just (Branch record{left = pair.left, right = pair.right})"
        -- Restrict both sizes to zero so the result's explicit index also holds.
        guarded=prefix++header++"if nOfTree pair.left = 0 and nOfTree pair.right = 0 then "++construction++" else Nothing end if end function"
        unguarded=prefix++header++construction++" end function"
    compileRecords 64 guarded `shouldSatisfy` either (const False) (const True)
    compileRecords 64 unguarded `shouldSatisfy` either (const True) (const False)
  it "filters finite quantified record inputs through their intrinsic relationship" $ do
    let source=unlines [ "type Level (n of type Whole) is one of | Low where n = 0 | High where n = 1 end type\n"
                       , "law shared is definition: for all (pair of type record{left of type Level m right of type Level m}) => nOfLevel pair.left = nOfLevel pair.right end for all end definition end law" ]
    case compileRecords 64 source of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> case (CoreTypes.makeRegistry (C.programDataDeclarations program),CoreDefinitions.prepareDefinitions program) of
        (Right registry,Right invoke) -> do
          let [property]=[p | u<-C.programUnits program,p<-C.unitProperties u,C.propertyName p=="shared"]
              [quantifier]=C.propertyInputs property
              binder=C.quantifiedBinder quantifier
          case finiteValuesWithRegistry registry 64 16 (C.binderType binder) of
            Right (Just values) -> do
              length values `shouldBe` 2
              mapM_ (\value -> CoreEval.evaluateValueProposition registry 64 invoke [(C.binderId binder,value)] (C.propertyBody property) `shouldBe` Right True) values
            other -> expectationFailure (show other)
        other -> expectationFailure "failed to prepare finite intrinsic record input"
