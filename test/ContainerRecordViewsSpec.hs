-- Parameterized storage and canonical products must interoperate through
-- finite, checked structural recursion rather than an unchecked cast.
module ContainerRecordViewsSpec (test_containerRecordViews) where

import Control.Monad (forM_)
import Data.Either (isLeft,isRight)
import Data.List (isInfixOf)
import LawSpec.Common (Diagnostic(..))
import Test.Hspec
import qualified LawSpec.Core as C
import qualified LawSpec.Model as S
import LawSpec.Frontend (compileCoreCanonical)
import LawSpec.Core.Validate (validateProgram)
import LawSpec.Core.Types (makeRegistry)
import LawSpec.Core.Definitions (prepareDefinitions)
import LawSpec.Core.Eval (evaluateValue,evaluateValueProposition)
import LawSpec.Core.RecordNormalize (normalizeProgramRecords)
import LawSpec.CoreEmit (emitPlan,targets)
import LawSpec.Testing (planTesting)
import qualified LawSpec.Core.RecordViewFunctions as Views

compile body=compileCoreCanonical 64 S.defaultGeneration [S.Source "container-records.lawspec" ("unit containerRecords\n"++body)]
checked result action=either (expectationFailure . show) action result
outcomes program=do
  validateProgram program `shouldBe` Right ()
  registry<-either fail pure (makeRegistry (C.programDataDeclarations program))
  invoke<-either (fail . show) pure (prepareDefinitions program)
  forM_ [property | owner<-C.programUnits program,property<-C.unitProperties owner,null (C.propertyInputs property)] $ \property ->
    evaluateValueProposition registry (C.programMachineBits program) invoke [] (C.propertyBody property) `shouldBe` Right True
  forM_ [example | owner<-C.programUnits program,property<-C.unitProperties owner,example<-C.propertyExamples property] $ \example -> do
    bindings<-either fail pure (mapM (\(name,value)->(,) name <$> evaluateValue registry (C.programMachineBits program) invoke [] value) (C.exampleBindings example))
    forM_ (C.exampleExpectations example) $ \expectation ->
      evaluateValueProposition registry (C.programMachineBits program) invoke bindings expectation `shouldBe` Right True
  plan<-either (fail . show) pure (planTesting program)
  forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight

header="type Batch (a :: Type) is one of | Batch of type List record{value :: a} end type\n"
first=unlines ["function first (batch :: Batch a) -> Maybe a is first matching case of batch:",
  "when Batch Nil then Nothing when Batch (Cons record{value = item} remaining) then Just item end case end function"]

test_containerRecordViews=describe "checked structural views through containers" $ do
  it "matches a generic nominal alternative carrying a list of records" $
    checked (compile (header++first++"law selected is definition: first (Batch [record{value = true}]) = Just true end end")) outcomes
  it "converts arbitrary input lists in both directions using checked functions" $
    checked (compile (header++unlines [
      "function pack (items :: List record{value :: a}) -> Batch a is Batch items end function",
      "function unpack (batch :: Batch a) -> List record{value :: a} is first matching case of batch: when Batch items then items end case end function",
      "law selected is definition: unpack (pack [record{value = true}, record{value = false}]) = [record{value = true}, record{value = false}] end end"])) outcomes
  it "admits concrete container projections through the same definition-contract checker" $
    checked (compile (header++unlines [
      "function unpack (batch :: Batch Bool) -> List record{value :: Bool} is first matching case of batch: when Batch items then items end case end function",
      "law selected is definition: unpack (Batch [record{value = true}]) = [record{value = true}] end end"])) outcomes
  it "checks concrete projections from named records containing structural lists" $
    checked (compile (unlines [
      "type Stored is a record{items :: List record{value :: Bool}} end type",
      "function unpack (batch :: Stored) -> List record{value :: Bool} is batch.items end function",
      "law selected is definition: unpack (Stored record{items = [record{value = true}]}) = [record{value = true}] end end"])) outcomes
  it "admits concrete reconstruction with a checked let and rejects undefined computations for their actual obligation" $ do
    let concrete expression=header++"function pack (items :: List record{value :: Bool}) -> Batch Bool is let unused = "++expression++" in Batch items end function"
    checked (compile (concrete "1"++"\nlaw selected is definition: first matching case of pack [record{value = true}]: when Batch items then items = [record{value = true}] end case end end")) outcomes
    case compile (concrete "1 / 0") of
      Left diagnostics -> diagnostics `shouldSatisfy` any (\diagnostic -> code diagnostic=="total" && "division" `isInfixOf` message diagnostic)
      Right _ -> expectationFailure "undefined reconstruction was accepted"
  it "handles finite nested lists without mistaking them for an expanding type cycle" $
    checked (compile (unlines [
      "type Nested (a :: Type) is one of | Nested of type List (List record{value :: a}) end type",
      "function unpack (nested :: Nested a) -> List (List record{value :: a}) is first matching case of nested: when Nested items then items end case end function",
      "law selected is definition: unpack (Nested [[record{value = true}], []]) = [[record{value = true}], []] end end"])) outcomes
  it "preserves closed literal tables without making their bindings executable adapters" $
    checked (compile (header++first++unlines [
      "law selected is definition: for all (batch :: Batch Bool) => first batch = first batch end end",
      "expect first batch = expected in table (batch, expected): row Batch [], Nothing row Batch [record{value = true}], Just true end end"])) outcomes
  it "reconstructs user-defined recursive containers and optional record payloads" $
    checked (compile (unlines [
      "type Chain (a :: Type) is one of | Stop | Link of type record{item :: a next :: Chain a} end type",
      "type Stored (a :: Type) is a record{items :: Chain record{value :: a} optional :: Maybe record{value :: a}} end type",
      "function chain (stored :: Stored a) -> Chain record{value :: a} is stored.items end function",
      "function optional (stored :: Stored a) -> Maybe record{value :: a} is stored.optional end function",
      "law selected is definition: let stored = Stored record{items = Link record{item = record{value = true}, next = Stop}, optional = Just record{value = true}} in chain stored = Link record{item = record{value = true}, next = Stop} and optional stored = Just record{value = true} end end"])) outcomes
  it "retains positive fields, definedness, exhaustiveness and termination without selected law checks" $ do
    forM_ [
      "type Stored is a record{items :: List record{value :: Nat}} end type\nfunction invalid (ignored :: ()) -> Stored is Stored record{items = [record{value = 0}]} end function",
      header++"function invalid (items :: List record{value :: Bool}) -> Batch Bool is let unused = 1 / 0 in Batch items end function",
      header++"function invalid (batch :: Batch a) -> a is first matching case of batch: when Batch (Cons record{value = item} remaining) then item end case end function",
      header++"function invalid (batch :: Batch a) -> List record{value :: a} is invalid batch end function"
      ] $ \body -> compile body `shouldSatisfy` isLeft
  it "evaluates closed record literals with nested containers without discarding source checks" $
    checked (compile (unlines [
      "type Stored (a :: Type) is a record{items :: List record{value :: a}} end type",
      "function first (stored :: Stored a) -> Maybe a is first matching case of stored.items: when Nil then Nothing when Cons record{value = item} remaining then Just item end case end function",
      "law selected is definition: for all (stored :: Stored Bool) => first stored = first stored end end",
      "expect first stored = expected in table (stored, expected): row Stored record{items = []}, Nothing row Stored record{items = [record{value = true}]}, Just true end end"])) outcomes
  it "does not allow record labels or nominal identities to change during reconstruction" $ do
    compile (header++"function invalid (items :: List record{other :: Bool}) -> Batch Bool is Batch items end function") `shouldSatisfy` isLeft
    compile (header++"type Named is a record{value :: Bool} end type\nfunction invalid (items :: List Named) -> Batch Bool is Batch items end function") `shouldSatisfy` isLeft
  it "keeps generated recursive definitions ordinary and normalization idempotent" $
    checked (compile (header++first++"law selected is definition: first (Batch [record{value = true}]) = Just true end end")) $ \program -> do
      outcomes program
      let helpers=[definition | owner<-C.programUnits program,C.unitId owner==Views.viewUnitId,definition<-C.unitDefinitions owner]
      helpers `shouldSatisfy` (not . null)
      forM_ helpers $ \definition -> do
        C.definitionOrchestrates definition `shouldBe` False
        Views.viewSignature definition `shouldSatisfy` (/=Nothing)
      normalizeProgramRecords program `shouldBe` Right program
  it "rejects a changed helper body before erasing any representation calls" $
    checked (compile (header++first++"law selected is definition: first (Batch [record{value = true}]) = Just true end end")) $ \program -> do
      let changed definition | Views.viewSignature definition/=Nothing = definition{C.definitionBody=
            C.Expr (C.expressionType (C.definitionBody definition)) (C.ExternalCall (C.Id "absent") []) (C.GeneratedFrom (C.Id "tampered"))}
          changed definition=definition
          invalid=program{C.programUnits=[owner{C.unitDefinitions=map changed (C.unitDefinitions owner)} | owner<-C.programUnits program]}
      normalizeProgramRecords invalid `shouldSatisfy` isLeft
  it "runs the complete container authoring demonstration at both machine widths" $ do
    text<-readFile "test/fixtures/canonical-container-records.lawspec"
    forM_ [32,64] $ \bits -> checked (compileCoreCanonical bits S.defaultGeneration [S.Source "containers.lawspec" text]) outcomes
