-- Original predicate calls must be admitted before their bodies are expanded.
module FieldDefinitionExpansionSpec (test_fieldDefinitionExpansion) where

import Control.Monad (forM_)
import Control.Exception (evaluate)
import System.Timeout (timeout)
import Data.Either (isLeft,isRight)
import Data.List (isInfixOf)
import Test.Hspec
import qualified LawSpec.Model as S
import qualified LawSpec.Core as C
import LawSpec.Common (Diagnostic(..),Artifact(..))
import LawSpec.Frontend (compileCoreCanonical)
import LawSpec.Core.Validate (validateProgram)
import LawSpec.Core.Types (makeRegistry)
import LawSpec.Core.Definitions (prepareDefinitions)
import LawSpec.Core.Value (Value(..))
import LawSpec.Core.Eval (evaluateValueProposition)
import LawSpec.Core.RecordNormalize (normalizeProgramRecords)
import LawSpec.CoreEmit (emitPlan,targets)
import LawSpec.Testing (planTesting)
import LawSpec.Discharge (dischargeEvidenceWith)
import LawSpec.Core.Evidence (Obligation(..),Status(..))
import qualified LawSpec.Core.Verification as V
import LawSpec.Scalar (Scalar(..))

compile bits body=compileCoreCanonical bits S.defaultGeneration
  [S.Source "field-predicates.lawspec" ("unit fieldPredicates\n"++body)]
checked result action=either (expectationFailure . show) action result
outcomes program=do
  validateProgram program `shouldBe` Right ()
  registry<-either fail pure (makeRegistry (C.programDataDeclarations program))
  invoke<-either (fail . show) pure (prepareDefinitions program)
  forM_ [property | owner<-C.programUnits program,property<-C.unitProperties owner,null (C.propertyInputs property)] $ \property ->
    evaluateValueProposition registry (C.programMachineBits program) invoke [] (C.propertyBody property) `shouldBe` Right True
  plan<-either (fail . show) pure (planTesting program)
  forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight
  [C.declarationName (C.definitionDeclaration definition) | owner<-C.programUnits program,definition<-C.unitDefinitions owner]
    `shouldSatisfy` all (not . isInfixOf "$lawspecFieldAdmission")
accept body=forM_ [32,64] $ \bits -> checked (compile bits body) outcomes
reject body=forM_ [32,64] $ \bits -> case compile bits body of
  Left diagnostics -> diagnostics `shouldSatisfy` all (\diagnostic -> code diagnostic/="parse")
  Right _ -> expectationFailure "invalid original field predicate call was accepted"
positive=unlines [
  "function positive (n :: UInt8) -> Bool is n > 0 end function",
  "type Positive is a record{value :: (n :: UInt8 where positive n)} end type",
  "function reciprocal (input :: Positive) -> Rational is 1 / input.value end function",
  "law selected is definition: reciprocal (Positive record{value = 2}) = rational(1,2) end end"]

test_fieldDefinitionExpansion=describe "checked field predicate expansion" $ do
  it "uses an expanded positive stored predicate without losing its strict argument" $ accept positive
  it "rejects a wrong argument type even when the predicate ignores its argument" $ reject $ unlines [
    "function keep (n :: Bool) -> Bool is true end function",
    "type Number is a record{value :: (n :: UInt8 where keep n)} end type",
    "function invalid (ignored :: ()) -> Number is Number record{value = 0} end function"]
  it "rejects an unproved refined argument even when the predicate ignores it" $ do
    forM_ [("Nat","Whole"),("(v :: UInt8 where v > 0)","UInt8")] $ \(parameter,field) -> reject $ unlines [
      "function keep (n :: "++parameter++") -> Bool is true end function",
      "type Number is a record{value :: (n :: "++field++" where keep n)} end type",
      "function invalid (ignored :: ()) -> Number is Number record{value = 0} end function"]
  it "checks calls under the restrictions of earlier fields and preceding guards" $ accept $ unlines [
    "function above (lower :: UInt8) (upper :: (n :: UInt8 where n > lower)) -> Bool is true end function",
    "type Interval is a record{lower :: UInt8 upper :: (n :: UInt8 where n > lower and above lower n)} end type",
    "function reciprocal (input :: Interval) -> Rational is 1 / (input.upper - input.lower) end function",
    "law selected is definition: reciprocal (Interval record{lower = 2, upper = 4}) = rational(1,2) end end"]
  it "does not lose a capability requirement on an unused generic argument" $ reject $ unlines [
    "function same (left :: a) (right :: a) -> Bool requires Eq a is true end function",
    "type Box (a :: Type) is a record{value :: (n :: a where same n n)} end type"]
  it "avoids capture by a local name that resembles an internal argument binder" $ accept $ unlines [
    "function keep (n :: Bool) -> Bool is let lawspecInline0_n = false in n end function",
    "type Enabled is a record{value :: (n :: Bool where keep n)} end type",
    "law selected is definition: (Enabled record{value = true}).value = true end end"]
  it "does not let one argument binding capture a later argument's free field" $ accept $ unlines [
    "function above (left :: UInt8) (right :: UInt8) -> Bool is right > left end function",
    "type Interval is a record{lawspecInline0_left :: UInt8 upper :: (n :: UInt8 where above 0 lawspecInline0_left and n > lawspecInline0_left)} end type",
    "law selected is definition: (Interval record{lawspecInline0_left = 2, upper = 4}).upper = 4 end end"]
  it "respects a field that shadows a global function" $ reject $ unlines [
    "function keep (n :: UInt8) -> Bool is true end function",
    "type Number is a record{keep :: Bool value :: (n :: UInt8 where keep n)} end type"]
  it "checks original calls inside nested structural fields" $ reject $ unlines [
    "function keep (n :: Bool) -> Bool is true end function",
    "type Number is a record{inner :: record{value :: (n :: UInt8 where keep n)}} end type"]
  it "retains definedness of an unused actual argument and strict body prefixes" $ do
    reject $ unlines [
      "function keep (n :: Rational) -> Bool is true end function",
      "type Number is a record{value :: (n :: UInt8 where keep (1 / 0))} end type"]
    reject $ unlines [
      "function keep (n :: UInt8) -> Bool is let ignored = 1 / 0 in true end function",
      "type Number is a record{value :: (n :: UInt8 where keep n)} end type"]
  it "does not erase a deferred runtime result contract through a transitive call" $ do
    let source=unlines [
          "function broken (n :: UInt8) -> (r :: Integer where r > n * n) is 0 end function",
          "function keep (n :: UInt8) -> Bool is broken n = 0 end function"]
    checked (compile 64 source) $ \program -> do
      invoke<-either (fail . show) pure (prepareDefinitions program)
      invoke (C.Id "fieldPredicates::broken") [ScalarValue (SInteger "UInt8" 0)] `shouldSatisfy` isLeft
    case compile 64 (source++"type Number is a record{value :: (n :: UInt8 where keep n)} end type") of
      Left diagnostics -> diagnostics `shouldSatisfy` any (\diagnostic -> code diagnostic=="field-predicate")
      Right _ -> expectationFailure "a deferred runtime contract was erased"
  it "keeps statically established result refinements usable" $ accept $ unlines [
    "function nonnegative (n :: UInt8) -> (r :: Integer where r >= 0) is n + 0 end function",
    "type Number is a record{value :: (n :: UInt8 where nonnegative n = n)} end type",
    "law selected is definition: (Number record{value = 0}).value = 0 end end"]
  it "keys validation by the original call even when expanded predicates are identical" $ do
    let body selected=unlines [
          "function keepNumber (n :: UInt8) -> Bool is true end function",
          "function keepFlag (n :: Bool) -> Bool is true end function",
          "type Number is a record{value :: (n :: UInt8 where "++selected++" n)} end type"]
    forM_ [32,64] $ \bits -> do
      compile bits (body "keepNumber") `shouldSatisfy` isRight
      compile bits (body "keepFlag") `shouldSatisfy` isLeft
      compile bits (body "keepNumber") `shouldSatisfy` isRight
  it "normalizes an admitted expanded predicate idempotently" $
    checked (compile 64 positive) $ \program -> normalizeProgramRecords program `shouldBe` Right program
  it "admits the same checked predicate in a direct anonymous signature" $ accept $ unlines [
    "function positive (n :: UInt8) -> Bool is n > 0 end function",
    "function reciprocal (input :: record{value :: (n :: UInt8 where positive n)}) -> Rational is 1 / input.value end function",
    "law selected is definition: reciprocal record{value = 2} = rational(1,2) end end"]
  it "checks original calls in direct anonymous signatures rather than only nominal fields" $ do
    reject $ unlines [
      "function keep (n :: Bool) -> Bool is true end function",
      "function invalid (input :: record{value :: (n :: UInt8 where keep n)}) -> Bool is true end function"]
    reject $ unlines [
      "function keep (n :: (v :: UInt8 where v > 0)) -> Bool is true end function",
      "function invalid (input :: record{value :: (n :: UInt8 where keep n)}) -> Bool is true end function"]
  it "retains dependent field restrictions in a direct anonymous type" $ accept $ unlines [
    "function above (lower :: UInt8) (upper :: UInt8) -> Bool is upper > lower end function",
    "function reciprocal (input :: record{lower :: UInt8 upper :: (n :: UInt8 where above lower n)}) -> Rational is 1 / (input.upper - input.lower) end function",
    "law selected is definition: reciprocal record{upper = 4, lower = 2} = rational(1,2) end end"]
  it "expands checked calls inside a structural GADT result index" $ accept $ unlines [
    "function positive (n :: UInt8) -> Bool is n > 0 end function",
    "type Reading (a :: Type) is one of | Reading of type a where a = record{value :: (n :: UInt8 where positive n)} end type",
    "function reciprocal (input :: Reading a) -> Rational is first matching case of input: when Reading payload then 1 / payload.value end case end function",
    "law selected is definition: reciprocal (Reading record{value = 2}) = rational(1,2) end end"]
  it "keeps validation-only names out of field diagnostics" $ do
    let body=unlines ["function keep (n :: Bool) -> Bool is true end function",
          "function invalid (input :: record{value :: (n :: UInt8 where keep n)}) -> Bool is true end function"]
    case compile 64 body of
      Left diagnostics -> do
        diagnostics `shouldSatisfy` any (isInfixOf "field restriction" . message)
        diagnostics `shouldSatisfy` all (not . isInfixOf "$lawspecFieldAdmission" . message)
      Right _ -> expectationFailure "invalid original call was accepted"
  it "keeps generic checked predicate calls valid at their concrete field types" $ accept $ unlines [
    "function positive (n :: a) -> Bool requires Integer a is n > 0 end function",
    "function reciprocal (input :: record{value :: (n :: UInt8 where positive n)}) -> Rational is 1 / input.value end function",
    "law selected is definition: reciprocal record{value = 2} = rational(1,2) end end"]
  it "expands a refinement alias before admitting its anonymous field" $ accept $ unlines [
    "function positive (n :: UInt8) -> Bool is n > 0 end function",
    "refinement Positive is (n :: UInt8 where positive n) end",
    "function reciprocal (input :: record{value :: Positive}) -> Rational is 1 / input.value end function",
    "law selected is definition: reciprocal record{value = 2} = rational(1,2) end end"]
  it "uses the same checked field predicate in a law's quantified record" $ accept $ unlines [
    "function positive (n :: UInt8) -> Bool is n > 0 end function",
    "law positiveFields is definition: for all (input :: record{value :: (n :: UInt8 where positive n)}) => input.value > 0 end end end"]
  it "resolves an imported predicate before expansion" $ forM_ [32,64] $ \bits -> checked
    (compileCoreCanonical bits S.defaultGeneration [
      S.Source "checks.lawspec" "unit checks\nfunction positive (n :: UInt8) -> Bool is n > 0 end function",
      S.Source "readings.lawspec" (unlines ["unit fieldPredicates", "import checks as check (positive)",
        "function reciprocal (input :: record{value :: (n :: UInt8 where check.positive n)}) -> Rational is 1 / input.value end function",
        "law selected is definition: reciprocal record{value = 2} = rational(1,2) end end"])]) outcomes
  it "checks the predicate-backed reading demonstration completely at both widths" $ do
    text<-readFile "test/fixtures/canonical-record-predicate-functions.lawspec"
    forM_ [32,64] $ \bits -> forM_
      ["test/fixtures/canonical-record-predicate-functions.lawspec",replicate 180 'a'++".lawspec"] $ \path -> checked
      (compileCoreCanonical bits S.defaultGeneration [S.Source path text]) $ \program -> do
        let properties=[property | owner<-C.programUnits program,property<-C.unitProperties owner]
        length properties `shouldBe` 6
        sum [length (C.propertyExamples property) | property<-properties] `shouldBe` 14
        case dischargeEvidenceWith (V.Verification [V.Exhaustive,V.Examples]) program of
          Left diagnostics -> expectationFailure (show diagnostics)
          Right evidence -> [obligationStatus item | item<-evidence,obligationStage item=="law"] `shouldBe` replicate 6 ExhaustivelyChecked
        outcomes program
  it "allocates distinct schema locals for strict predicate lets" $
    checked (compile 64 (unlines [
      "function above (lower :: UInt8) (upper :: UInt8) -> Bool is upper > lower end function",
      "type Interval is a record{lower :: UInt8 upper :: (n :: UInt8 where above lower n)} end type"])) $ \program -> do
      plan<-either (fail . show) pure (planTesting program)
      forM_ ["java","javascript","typescript","go","haskell"] $ \target -> do
        artifacts<-either (fail . show) pure (emitPlan target plan)
        concatMap artifactContent artifacts `shouldSatisfy` \text ->
          not ("_invalid_field" `isInfixOf` text || "invalidField" `isInfixOf` text)
  it "bounds recursive expansion through a type annotation" $ do
    let source=unlines [
          "function keep (n :: UInt8) -> Bool is let reading = (record{value = n} :: record{value :: (v :: UInt8 where keep v)}) in true end function",
          "type Number is a record{value :: (n :: UInt8 where keep n)} end type"]
    result<-timeout 10000000 (evaluate (isLeft (compile 64 source)))
    result `shouldBe` Just True
  it "preserves the declared IEEE argument context during expansion" $ do
    let source="function finite (n :: Float64) -> Bool is n + 0.2 = 0.3 end function\n"
    checked (compile 64 source) $ \program -> do
      invoke<-either (fail . show) pure (prepareDefinitions program)
      invoke (C.Id "fieldPredicates::finite") [ScalarValue (SFloat "Float64" "3fb999999999999a")]
        `shouldBe` Right (ScalarValue (SBool False))
    reject (source++unlines [
      "type Number is a record{value :: (n :: UInt8 where finite 0.1)} end type",
      "function invalid (ignored :: ()) -> Number is Number record{value = 0} end function"])
  it "keeps the result context of a nested generic call" $ reject $ unlines [
    "function identity (n :: a) -> a is n end function",
    "function finite (n :: Float64) -> Bool is n + 0.2 = 0.3 end function",
    "type Number is a record{value :: (n :: UInt8 where finite (identity 0.1))} end type",
    "function invalid (ignored :: ()) -> Number is Number record{value = 0} end function"]
  it "instantiates generic argument carriers from a GADT constructor before expansion" $ do
    let source=unlines [
          "type NumberKind (a :: Type) is one of | Floating of type () where a = Float64 end type",
          "function finite (kind :: NumberKind a) (n :: a) -> Bool is first matching case of kind: when Floating ignored then n + 0.2 = 0.3 end case end function"]
    accept (source++"law oracle is definition: finite (Floating ()) 0.1 = false end end")
    reject (source++unlines [
      "type Number is a record{value :: (n :: UInt8 where finite (Floating ()) 0.1)} end type",
      "function invalid (ignored :: ()) -> Number is Number record{value = 0} end function"])
  it "stores the contextual Float64 constant rather than an exact decimal" $
    checked (compile 64 (unlines [
      "function identity (n :: a) -> a is n end function",
      "function ignored (n :: Float64) -> Bool is true end function",
      "type Enabled is a record{value :: (n :: Bool where ignored (identity 0.1))} end type",
      "law selected is definition: (Enabled record{value = true}).value = true end end"])) $ \program -> do
        outcomes program
        let walk expression=expression:concatMap walk (C.children expression)
            constants=[scalar | declaration<-C.programDataDeclarations program,constructor<-C.dataConstructors declaration,
              predicate<-C.constructorPredicates constructor,expression<-walk predicate,C.Constant scalar<-[C.expressionNode expression]]
        constants `shouldSatisfy` elem (SFloat "Float64" "3fb999999999999a")
        constants `shouldSatisfy` all (\scalar->case scalar of SDecimal _ _->False; _->True)
  it "keeps GADT givens local while typing nested predicate calls at a concrete carrier" $ accept $ unlines [
    "type NumberKind (a :: Type) is one of | Floating of type () where a = Float64 end type",
    "function finite (n :: Float64) -> Bool is n + 0.2 = 0.3 end function",
    "function selected (kind :: NumberKind a) (n :: a) -> Bool is first matching case of kind: when Floating ignored then finite n end case end function",
    "type Sample is a record{kind :: NumberKind Float64 value :: (n :: Float64 where selected kind n)} end type",
    "law oracle is definition: selected (Floating ()) 0.1 = false end end"]
  it "rejects a stored generic GADT match that Core cannot represent rather than dropping its branch" $ do
    let source=unlines [
          "type NumberKind (a :: Type) is one of | Floating of type () where a = Float64 end type",
          "function finite (n :: Float64) -> Bool is n + 0.2 = 0.3 end function",
          "function selected (kind :: NumberKind a) (n :: a) -> Bool is first matching case of kind: when Floating ignored then finite n end case end function",
          "type Sample (a :: Type) is a record{kind :: NumberKind a value :: (n :: a where selected kind n)} end type"]
    forM_ [32,64] $ \bits -> case compile bits source of
      Left diagnostics -> diagnostics `shouldSatisfy` any (isInfixOf "inaccessible match constructor" . message)
      Right _ -> expectationFailure "a generic stored match with no Core equality evidence was accepted"
  it "uses the pattern typer's local field types inside an expanded list predicate" $ accept $ unlines [
    "function positive (n :: UInt8) -> Bool is n > 0 end function",
    "function firstPositive (values :: List UInt8) -> Bool is first matching case of values: when Nil then false when Cons head tail then positive head end case end function",
    "function read (input :: record{values :: (xs :: List UInt8 where firstPositive xs)}) -> List UInt8 is input.values end function",
    "law selected is definition: read record{values = [2]} = ([2] :: List UInt8) end end"]
