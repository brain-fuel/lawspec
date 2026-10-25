module SearchSpec (test_boundedWitnessSearchPreservesEvidence) where

import Test.Hspec
import Data.Either (isLeft, isRight)
import Data.List (isInfixOf)
import LawSpec.Common
import qualified LawSpec.Core as C
import LawSpec.Core.Value (Value(..))
import LawSpec.Core.Eval (evaluateValueProposition)
import LawSpec.Core.Types (makeRegistry)
import LawSpec.Core.Evidence (Obligation(..),Status(..))
import qualified LawSpec.Core.Verification as V
import LawSpec.Frontend (compileCoreCanonical)
import LawSpec.Discharge (dischargeEvidenceWith)
import qualified LawSpec.Testing as T
import LawSpec.CoreEmit (emitPlan,targets)
import qualified LawSpec.Backend as B
import LawSpec.Scalar (Scalar(..))
import Data.IORef
import System.IO.Unsafe (unsafePerformIO)
import Control.Exception (evaluate)

compile :: String -> [String] -> [String] -> Either [Diagnostic] C.Program
compile body strategies settings = compileCoreCanonical 64 defaultGeneration
  [Source "search.lawspec" ("unit example.search\n\n" ++ body ++ "\nend unit\n"),
   Source "search.harness.lawspec" (unlines
     (["harness example.search.testing for example.search is"] ++ strategies ++ ["for law selected"] ++ settings ++ ["end for law", "end harness"]))]

law :: String -> String
law claim = "law selected is definition: " ++ claim ++ " end definition end law\n"

checked :: Either [Diagnostic] C.Program -> (C.Program -> Expectation) -> Expectation
checked value body = either (expectationFailure . show) body value

statuses :: [V.Layer] -> C.Program -> Either [Diagnostic] [Status]
statuses layers program = map obligationStatus . filter ((== "law") . obligationStage) <$>
  dischargeEvidenceWith (V.Verification layers) program

test_boundedWitnessSearchPreservesEvidence :: Spec
test_boundedWitnessSearchPreservesEvidence = describe "bounded scoped witness search" $ do
  it "finds a constructive default witness without enumerating an infinite domain" $
    checked (compile (law "there exists (answer :: Integer) such that answer = answer end exists") [] []) $ \program -> do
      statuses [V.Exhaustive] program `shouldBe` Right [ExhaustivelyChecked]
      statuses [V.Proof] program `shouldBe` Right [Proved]
  it "retains signed literal seeds beyond the small integer candidate range" $
    checked (compile (law "there exists (answer :: Integer) such that answer = -1000 end exists") [] []) $ \program ->
      statuses [V.Exhaustive] program `shouldBe` Right [ExhaustivelyChecked]
  it "keeps generated search plans bounded when one hundred candidates miss" $
    checked (compile (law "there exists (answer :: Integer) such that answer * answer = -1 end exists") [] []) $ \program ->
      case T.planTesting program of
        Left ds -> expectationFailure (show ds)
        Right plan -> do
          let property = head [T.plannedProperty p | u <- T.plannedUnits plan,p <- T.plannedProperties u]
              count expression = 1 + sum (map count (C.children expression))
              depth expression = 1 + maximum (0 : map depth (C.children expression))
          sum (map count (C.propositionExpressions (C.propertyBody property))) `shouldSatisfy` (< 20000)
          maximum (map depth (C.propositionExpressions (C.propertyBody property))) `shouldSatisfy` (< 80)
          case C.propertyBody property of
            C.Equation _ actual _ -> B.prettyExpr actual `shouldBe` "the scoped requirement"
            _ -> expectationFailure "a search plan must lower to an ordinary checked equation"
          emitPlan "javascript" plan `shouldSatisfy` isRight
  it "keeps bounded misses inconclusive through positive and negative existence" $ do
    mapM_ (\claim -> checked (compile (law claim) [] []) $ \program ->
      statuses [V.Exhaustive] program `shouldBe` Right [Incomplete])
      ["there exists (answer :: Integer) such that answer * answer = -1 end exists",
       "there must not exist (answer :: Integer) such that answer * answer = -1 end exists"]
  it "uses a scoped strategy for finite outer inputs and emits every target" $
    checked (compile (law "for all (flag :: Bool) => there exists (answer :: Integer) such that answer = (if flag then 1 else 2 end if) end exists end for all")
      ["strategy answers :: Integer is one of 1, 2 end strategy"] ["use answers for definition.flag.answer"]) $ \program -> do
      statuses [V.Exhaustive] program `shouldBe` Right [ExhaustivelyChecked]
      case T.planTesting program of
        Left ds -> expectationFailure (show ds)
        Right plan -> mapM_ (\target -> emitPlan target plan `shouldSatisfy` isRight) targets
  it "never treats a strategy's finite choice list as complete absence evidence" $
    checked (compile (law "there must not exist (answer :: Integer) such that answer = 2 end exists")
      ["strategy answers :: Integer is one of 0, 1 end strategy"] ["use answers for answer"]) $ \program ->
        statuses [V.Exhaustive] program `shouldBe` Right [Incomplete]
  it "retains complete finite fallback independently of a scoped strategy" $
    checked (compile (law "there exists (answer :: Bool) such that answer = true end exists")
      ["strategy answers :: Bool is one of false end strategy"] ["use answers for answer"]) $ \program ->
        statuses [V.Exhaustive] program `shouldBe` Right [ExhaustivelyChecked]
  it "refutes nonexistence from a verified bounded witness" $
    checked (compile (law "there must not exist (answer :: Integer) such that answer = 1 end exists")
      ["strategy answers :: Integer is one of 1 end strategy"] ["use answers for answer"]) $ \program ->
        case statuses [V.Exhaustive] program of
          Left ds -> map code ds `shouldBe` ["refuted"]
          Right value -> expectationFailure (show value)
  it "uses a counterexample to disprove a nested universal without proving a sampled universal" $ do
    let strategy = ["strategy answers :: Integer is one of 1 end strategy"]
    checked (compile (law "must not for all (answer :: Integer) => answer = 0 end for all") strategy ["use answers for answer"]) $ \program ->
      statuses [V.Exhaustive] program `shouldBe` Right [ExhaustivelyChecked]
    checked (compile (law "must not (for all (answer :: Integer) => answer = 1 end for all)") strategy ["use answers for answer"]) $ \program ->
      statuses [V.Exhaustive] program `shouldBe` Right [Incomplete]
  it "keeps sibling paths unambiguous and rejects duplicate aliases" $ do
    let body = law "(there exists (answer :: Integer) such that answer = 1 end exists) and (there exists (answer :: Integer) such that answer = 1 end exists)"
        strategy = ["strategy answers :: Integer is one of 1 end strategy"]
    compile body strategy ["use answers for answer"] `shouldSatisfy` either (any (isInfixOf "ambiguous" . message)) (const False)
    checked (compile body strategy ["use answers for branch1.answer","use answers for definition.branch2.answer"]) $ \program ->
      statuses [V.Exhaustive] program `shouldBe` Right [ExhaustivelyChecked]
    compile (law "there exists (answer :: Integer) such that answer = 1 end exists") strategy
      ["use answers for answer","use answers for definition.answer"] `shouldSatisfy` isLeft
  it "points invalid target and type selections at their original harness statement" $ do
    let body = law "there exists (answer :: Integer) such that answer = 1 end exists"
        choices = [(["strategy answers :: Integer is one of 1 end strategy"],["use answers for missing"]),
          (["strategy answers :: Bool is one of false end strategy"],["use answers for answer"])]
    mapM_ (\(strategies,settings) -> case compile body strategies settings of
      Left ds -> map at ds `shouldBe` [Just (Location "search.harness.lawspec" 4 1)]
      Right _ -> expectationFailure "an invalid target or type was accepted") choices
  it "preserves outer input strategies and accepts their explicit definition path" $
    checked (compile (law "for all (answer :: Integer) => answer = answer end for all")
      ["strategy answers :: Integer is one of 1 end strategy"] ["use answers for definition.answer"]) $ \program -> do
        let harness = head [C.propertyHarness p | u <- C.programUnits program,p <- C.unitProperties u]
        length (C.harnessDraws harness) `shouldBe` 1
        C.harnessSearches harness `shouldBe` []
  it "composes dependent binds and filters without capturing another strategy's locals" $
    checked (compile (law "there exists (answer :: Integer) such that answer = 4 end exists")
      ["strategy bases :: Integer is one of 0, 3 end strategy",
       "strategy answers :: Integer is (bind base :: Integer from bases in one of base + 1 end bind) such that it > 0 end strategy"]
      ["use answers for answer"]) $ \program ->
        statuses [V.Exhaustive] program `shouldBe` Right [ExhaustivelyChecked]
  it "respects a filter's discard limit and keeps exhaustion inconclusive" $
    checked (compile (law "there exists (answer :: Integer) such that answer = 1 end exists")
      ["strategy answers :: Integer is (one of -2, -1, 1) such that it > 0 at most 1 discards end strategy"]
      ["use answers for answer"]) $ \program ->
        statuses [V.Exhaustive] program `shouldBe` Right [Incomplete]
  it "specializes generic checked functions used only by a scoped strategy" $
    checked (compile ("function keep (value :: a) -> a is value end function\n" ++
      law "there exists (answer :: Text) such that answer = \"ready\" end exists")
      ["strategy words :: Text is one of keep \"ready\" end strategy","strategy answers :: Text is words end strategy"]
      ["use answers for answer"]) $ \program ->
        statuses [V.Exhaustive] program `shouldBe` Right [ExhaustivelyChecked]
  it "specializes a generic predicate used only by a strategy refinement" $
    checked (compile ("function keep (value :: a) -> a is value end function\n" ++
      law "there exists (answer :: Integer) such that answer > 0 end exists")
      ["strategy answers :: (value :: Integer where keep (value > 0)) is any end strategy"]
      ["use answers for answer"]) $ \program ->
        statuses [V.Exhaustive] program `shouldBe` Right [ExhaustivelyChecked]
  it "lets a configured witness and a selected strategy cooperate" $ do
    let body = law "there exists (answer :: Integer) such that answer = 1 end exists"
    checked (compile body ["strategy answers :: Integer is one of 1 end strategy"]
      ["witness 0 for answer","use answers for answer"]) $ \program ->
        statuses [V.Exhaustive] program `shouldBe` Right [ExhaustivelyChecked]
    checked (compile body [] ["witness 0 for answer"]) $ \program ->
      statuses [V.Exhaustive] program `shouldBe` Right [Incomplete]
  it "rechecks dependent restrictions when enclosing inputs change during shrinking" $
    checked (compile (law "for all (base :: Integer) => there exists (answer :: Whole where answer + 0 > base) such that answer + 0 > base end exists end for all") [] []) $ \program ->
      case (makeRegistry (C.programDataDeclarations program),T.planTesting program) of
        (Right registry,Right plan) -> do
          let property = head [T.plannedProperty p | u <- T.plannedUnits plan,p <- T.plannedProperties u]
              input = C.binderId (C.quantifiedBinder (head (C.propertyInputs property)))
              invoke _ _ = Left "this candidate search calls no functions"
          mapM_ (\base -> evaluateValueProposition registry 64 invoke [(input,ScalarValue (SInteger "Integer" base))]
            (C.propertyBody property) `shouldBe` Right True) [100,50,25,0,-1,-100]
        (Left message,_) -> expectationFailure message
        (_,Left diagnostics) -> expectationFailure (show diagnostics)
  it "keeps typed obligations unchanged and no selected checks unverified" $ do
    let body = law "there exists (answer :: Integer) such that answer = 1 end exists"
    checked (compile body [] []) $ \without ->
      checked (compile body ["strategy answers :: Integer is one of 1 end strategy"] ["use answers for answer"]) $ \with -> do
        let claims program = [C.propertyBody p | u <- C.programUnits program,p <- C.unitProperties u]
        claims with `shouldBe` claims without
        statuses [] with `shouldBe` Right [NotVerified]
  it "rejects unchecked and effectful strategy computations even with law checks unselected" $ do
    compile ("native :: Bool -> Integer\n" ++ law "there exists (answer :: Integer) such that answer = 1 end exists")
      ["strategy answers :: Integer is one of native true end strategy"] ["use answers for answer"] `shouldSatisfy` isLeft
  it "evaluates a visited filtered checked candidate once" $
    checked (compile ("function build (flag :: Bool) -> Text is \"ready\" end function\n" ++
      law "there exists (answer :: Text) such that answer = \"ready\" end exists")
      ["strategy answers :: Text is (one of build true) such that it = \"ready\" end strategy"]
      ["use answers for answer"]) $ \program -> do
        counter <- newIORef (0 :: Int)
        let invoke _ _ = unsafePerformIO $ modifyIORef' counter (+1) >> pure (Right (ScalarValue (SSequence "Text" (map fromEnum "ready"))))
        case (makeRegistry (C.programDataDeclarations program),T.planTesting program) of
          (Right registry,Right plan) -> do
            let property = head [T.plannedProperty p | u <- T.plannedUnits plan,p <- T.plannedProperties u]
            result <- evaluate (evaluateValueProposition registry 64 invoke [] (C.propertyBody property))
            result `shouldBe` Right True
            readIORef counter `shouldReturn` 1
          (Left message,_) -> expectationFailure message
          (_,Left diagnostics) -> expectationFailure (show diagnostics)
  it "visits bounded affine points once and skips out-of-range offsets before conversion" $
    checked (compile ("probe :: Int8 -> Bool\n" ++ law
      "for all (base :: Integer) => there does not exist (candidate :: Int8 where candidate + 0 >= base - 2 and candidate + 0 <= base + 2) such that probe candidate end exists end for all") [] []) $ \program -> do
      seen <- newIORef ([] :: [[Value]])
      let invoke _ arguments = unsafePerformIO $ do
            modifyIORef' seen (++ [arguments])
            pure (Right (ScalarValue (SBool False)))
      case (makeRegistry (C.programDataDeclarations program),T.planTesting program) of
        (Right registry,Right plan) -> do
          let property = head [T.plannedProperty p | u <- T.plannedUnits plan,p <- T.plannedProperties u]
              input = C.binderId (C.quantifiedBinder (head (C.propertyInputs property)))
          mapM_ (\base -> do
            writeIORef seen []
            result <- evaluate (evaluateValueProposition registry 64 invoke
              [(input,ScalarValue (SInteger "Integer" base))] (C.propertyBody property))
            result `shouldBe` Right True
            readIORef seen `shouldReturn`
              [[ScalarValue (SInteger "Int8" n)] | n <- [max (-128) (base-2)..min 127 (base+2)]])
            [-131,-129,-128,0,127,129]
        (Left message,_) -> expectationFailure message
        (_,Left diagnostics) -> expectationFailure (show diagnostics)
  it "checks the complete bounded search demonstration and every native plan" $ do
    let path = "examples/rc1/bounded-witness-search.lawspec"
    source <- readFile path
    checked (compileCoreCanonical 64 defaultGeneration [Source path source]) $ \program -> do
      case statuses [V.Proof,V.Exhaustive] program of
        Left ds -> expectationFailure (show ds)
        Right evidence -> do
          length evidence `shouldBe` 9
          evidence `shouldSatisfy` all (`elem` [Proved,ExhaustivelyChecked])
      case T.planTesting program of
        Left ds -> expectationFailure (show ds)
        Right plan -> mapM_ (\target -> emitPlan target plan `shouldSatisfy` isRight) targets
