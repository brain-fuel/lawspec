module WitnessSpec (test_constructiveWitnessesPreserveScopedMeaning) where

import Test.Hspec
import Data.Either (isLeft, isRight)
import Data.List (isInfixOf)
import qualified LawSpec.Core as C
import LawSpec.Common
import LawSpec.Frontend (compileCoreCanonical)
import LawSpec.Discharge (dischargeEvidenceWith)
import LawSpec.Core.Evidence (Obligation(..), Status(..))
import qualified LawSpec.Core.Verification as V
import LawSpec.Testing (planTesting, plannedUnits, plannedProperties)
import qualified LawSpec.Testing as Testing
import LawSpec.Core.Eval (evaluateValueProposition)
import LawSpec.Core.Types (makeRegistry)
import LawSpec.Core.Value (Value(..))
import LawSpec.Scalar (Scalar(..))
import Data.IORef
import System.IO.Unsafe (unsafePerformIO)
import Control.Exception (evaluate)
import LawSpec.CoreEmit (emitPlan, targets)
import LawSpec.SourceText (formatSource)

compile :: String -> [String] -> Either [Diagnostic] C.Program
compile body settings = compileCoreCanonical 64 defaultGeneration
  [ Source "witness.lawspec" ("unit example.witness\n" ++ body)
  , Source "witness.harness.lawspec" (unlines
      (["harness example.witness.testing for example.witness is", "for law selected"] ++ settings ++ ["end"])) ]

law :: String -> String
law proposition = "law selected is definition: " ++ proposition ++ " end end"

statuses :: [V.Layer] -> C.Program -> Either [Diagnostic] [Status]
statuses layers program = map obligationStatus . filter ((== "law") . obligationStage) <$>
  dischargeEvidenceWith (V.Verification layers) program

checked :: Either [Diagnostic] C.Program -> (C.Program -> Expectation) -> Expectation
checked value body = case value of Left ds -> expectationFailure (show ds); Right program -> body program

test_constructiveWitnessesPreserveScopedMeaning :: Spec
test_constructiveWitnessesPreserveScopedMeaning = describe "constructive harness witnesses" $ do
  it "checks unbounded witnesses for every finite outer input and emits every target" $
    checked (compile (law "for all (flag :: Bool) => there exists (answer :: Integer) such that answer = (if flag then 1 else 2 end if) end end")
      ["witness (if flag then 1 else 2 end if) for definition.flag.answer"]) $ \program -> do
        statuses [V.Exhaustive] program `shouldBe` Right [ExhaustivelyChecked]
        case planTesting program of
          Left ds -> expectationFailure (show ds)
          Right plan -> mapM_ (\target -> emitPlan target plan `shouldSatisfy` isRight) targets
  it "proves a constructive successor for an unbounded universal domain" $
    checked (compile (law "for all (value :: Integer) => there exists (answer :: Integer where answer > value) such that answer = value + 1 end end")
      ["witness value + 1 for value.answer"]) $ \program ->
        statuses [V.Proof] program `shouldBe` Right [Proved]
  it "leaves failed unbounded candidates inconclusive, including under negation" $ do
    let claims = ["there exists (answer :: Integer) such that answer = 1 end",
          "there does not exist (answer :: Integer) such that answer = 1 end"]
    mapM_ (\claim -> checked (compile (law claim) ["witness 0 for answer"]) $ \program ->
      statuses [V.Exhaustive] program `shouldBe` Right [Incomplete]) claims
  it "refutes nonexistence only when a verified witness supplies a counterexample" $
    checked (compile (law "there must not exist (answer :: Integer) such that answer = 1 end")
      ["witness 1 for answer"]) $ \program -> case statuses [V.Exhaustive] program of
        Left ds -> map code ds `shouldBe` ["refuted"]
        Right value -> expectationFailure (show value)
  it "retains complete finite fallback when a configured candidate fails" $
    checked (compile (law "for all (flag :: Bool) => there exists (answer :: Bool) such that answer = flag end end")
      ["witness false for answer"]) $ \program ->
        statuses [V.Exhaustive] program `shouldBe` Right [ExhaustivelyChecked]
  it "preserves lexical shadowing and lets a later witness depend on an earlier one" $
    checked (compile (law ("for all (value :: Bool) => there exists (value :: Integer where value > 0) such that " ++
      "there exists (answer :: Integer) such that answer = value + 1 end end end"))
      ["witness (if value then 1 else 2 end if) for value.value", "witness value + 1 for value.value.answer"]) $ \program ->
        statuses [V.Exhaustive] program `shouldBe` Right [ExhaustivelyChecked]
  it "requires a qualified path when sibling existential names repeat" $ do
    let body = law "(there exists (answer :: Integer) such that answer = 1 end) and (there exists (answer :: Integer) such that answer = 2 end)"
    compile body ["witness 1 for answer"] `shouldSatisfy` either (any (isInfixOf "ambiguous" . message)) (const False)
    checked (compile body ["witness 1 for branch1.answer", "witness 2 for definition.branch2.answer"]) $ \program ->
      statuses [V.Exhaustive] program `shouldBe` Right [ExhaustivelyChecked]
  it "does not change the proposition or claim verification with no selected layers" $ do
    let body = law "there exists (answer :: Integer) such that answer = 1 end"
    checked (compile body ["witness 0 for answer"]) $ \withWitness ->
      checked (compile body []) $ \withoutWitness -> do
        let assertions program = [C.propertyBody p | u <- C.programUnits program,p <- C.unitProperties u]
        assertions withWitness `shouldBe` assertions withoutWitness
        statuses [] withWitness `shouldBe` Right [NotVerified]
  it "rejects unknown, universal, duplicate, self-dependent and ill-typed selections" $ do
    let body = law "for all (flag :: Bool) => there exists (answer :: Integer) such that answer = 1 end end"
        invalid = [["witness 1 for missing"], ["witness 1 for flag"], ["witness true for answer"],
          ["witness answer for answer"], ["witness 1 for answer", "witness 2 for flag.answer"]]
    mapM_ (\settings -> compile body settings `shouldSatisfy` isLeft) invalid
  it "accepts checked generic functions used only by the witness strategy" $
    checked (compile ("function same (value :: a) -> a is value end function\n" ++
      law "for all (flag :: Bool) => there exists (answer :: Integer) such that answer = (if flag then 1 else 2 end if) end end")
      ["witness same (if flag then 1 else 2 end if) for answer"]) $ \program ->
        statuses [V.Exhaustive] program `shouldBe` Right [ExhaustivelyChecked]
  it "does not turn IEEE non-reflexivity into an existence proof" $
    checked (compile (law "there exists (answer :: Float64) such that answer = answer end")
      ["witness float64Bits(\"7ff8000000000000\") for answer"]) $ \program -> do
        statuses [V.Exhaustive] program `shouldBe` Right [Incomplete]
        statuses [V.Proof] program `shouldBe` Right [Incomplete]
  it "keeps imported values behind lexical binders introduced by reusable-law expansion" $ do
    let library = Source "library.lawspec" (unlines
          ["unit library", "function input (flag :: Bool) -> Bool is not flag end function",
           "law reusable (select :: Bool -> Integer) is definition:",
           "for all (input :: Bool) => there exists (answer :: Integer) such that answer = select input end end end end"])
        consumer = Source "consumer.lawspec" (unlines
          ["unit consumer", "import library as lib (input, law reusable)",
           "function select (flag :: Bool) -> Integer is if flag then 1 else 2 end if end function",
           "law selected is definition: apply law lib.reusable select end end"])
        harness = Source "consumer.harness.lawspec" (unlines
          ["harness consumer.testing for consumer is", "for law selected",
           "witness (if input then 1 else 2 end if) for input.answer", "end"])
    checked (compileCoreCanonical 64 defaultGeneration [library,consumer,harness]) $ \program ->
      statuses [V.Exhaustive] program `shouldBe` Right [ExhaustivelyChecked]
  it "reports missing and ill-typed witness settings at their harness source" $ do
    let body = law "there exists (answer :: Integer) such that answer = 1 end"
    mapM_ (\setting -> case compile body [setting] of
      Left ds -> map at ds `shouldBe` [Just (Location "witness.harness.lawspec" 3 1)]
      Right _ -> expectationFailure "an invalid witness setting was accepted")
      ["witness 1 for missing", "witness false for answer"]
  it "checks candidate restrictions instead of treating a typed value as a valid witness" $
    checked (compile (law "there exists (answer :: Integer where answer > 0) such that answer = answer end")
      ["witness 0 for answer"]) $ \program -> do
        statuses [V.Exhaustive] program `shouldBe` Right [Incomplete]
        statuses [V.Proof] program `shouldBe` Right [Incomplete]
  it "preserves known counterexamples after another outer input has an incomplete witness" $
    checked (compile (law ("for all (flag :: Bool) => (there exists (answer :: Integer) such that answer = 1 end) " ++
      "and flag end")) ["witness 0 for answer"]) $ \program ->
        case statuses [V.Exhaustive] program of
          Left ds -> map code ds `shouldContain` ["refuted"]
          Right value -> expectationFailure (show value)
  it "keeps effectful and unchecked native calls out of witness expressions" $ do
    let body = "native :: Bool -> Integer\n" ++ law "there exists (answer :: Integer) such that answer = 1 end"
    compile body ["witness native true for answer"] `shouldSatisfy` isLeft
  it "keeps witness settings inside selected laws" $ do
    let inputs = [Source "law.lawspec" ("unit example.witness\n" ++ law "there exists (answer :: Integer) such that answer = 1 end"),
          Source "harness.lawspec" "harness example.witness.testing for example.witness is\nwitness 1 for answer\nend"]
    compileCoreCanonical 64 defaultGeneration inputs `shouldSatisfy` isLeft
  it "keeps line-scoped witness settings intact through formatting" $ do
    let input = Source "formatted.lawspec" (unlines ["unit example.witness",law "there exists (answer :: Integer) such that answer = 1 end",
          "harness example.witness.testing for example.witness is", "for law selected", "witness 1 for definition.answer", "end"])
        formatted = formatSource input
    formatSource formatted `shouldBe` formatted
    compileCoreCanonical 64 defaultGeneration [formatted] `shouldSatisfy` isRight
  it "keeps phrase delimiters, named infix calls and record fields away from the witness separator" $ do
    let definitions = unlines
          ["function add (left :: Integer) (right :: Integer) -> Integer is left + right end function",
           "function \"|add for approval| (left :: Integer) (right :: Integer) -> Integer is left + right end function"]
        body = definitions ++ law "for all (value :: Integer) => there exists (answer :: Integer) such that answer = value + 1 end end"
        expressions = ["add value 1", "value `add 1", "\"|add for approval| value 1", "value `|add for approval| 1"]
    mapM_ (\expression -> checked (compile body ["witness " ++ expression ++ " for answer"]) $ \program ->
      statuses [V.Proof] program `shouldBe` Right [Proved]) expressions
    checked (compile ("type Box is a record{for :: Integer} end type\n" ++
      law "there exists (box :: Box) such that box.for = 1 end") ["witness Box record{for = 1} for box"]) $ \program ->
        statuses [V.Exhaustive] program `shouldBe` Right [ExhaustivelyChecked]
  it "evaluates a visited constructive candidate once in the shared executor" $
    checked (compile ("function build (flag :: Bool) -> Text is \"ready\" end function\n" ++
      law "for all (flag :: Bool) => there exists (answer :: Text) such that answer = \"ready\" end end")
      ["witness build flag for answer"]) $ \program -> do
        counter <- newIORef (0 :: Int)
        let invoke _ _ = unsafePerformIO $ do
              modifyIORef' counter (+1)
              pure (Right (ScalarValue (SSequence "Text" (map fromEnum "ready"))))
        case (makeRegistry (C.programDataDeclarations program),planTesting program) of
          (Right registry,Right plan) -> do
            let property = head [Testing.plannedProperty p | u <- plannedUnits plan,p <- plannedProperties u]
                env = [(C.binderId (C.quantifiedBinder q),ScalarValue (SBool False)) | q <- C.propertyInputs property]
            result <- evaluate (evaluateValueProposition registry 64 invoke env (C.propertyBody property))
            result `shouldBe` Right True
            readIORef counter `shouldReturn` 1
          (Left message,_) -> expectationFailure message
          (_,Left diagnostics) -> expectationFailure (show diagnostics)
  it "checks the complete constructive demonstration and all target plans" $ do
    text <- readFile "examples/rc1/constructive-witnesses.lawspec"
    checked (compileCoreCanonical 64 defaultGeneration [Source "constructive-witnesses.lawspec" text]) $ \program -> do
      case statuses [V.Proof,V.Exhaustive,V.Property,V.Examples] program of
        Right evidence -> do
          length evidence `shouldBe` 6
          evidence `shouldSatisfy` all (`elem` [Proved,ExhaustivelyChecked])
        Left ds -> expectationFailure (show ds)
      case planTesting program of
        Left ds -> expectationFailure (show ds)
        Right plan -> mapM_ (\target -> emitPlan target plan `shouldSatisfy` isRight) targets
