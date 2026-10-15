-- | Whole-unit collection retains structural declarations for normal admission.
-- ref:DEC-typed-core-boundary ref:DEC-total-definitions
module SourceRecordUnitSpec (test_recordUnitsCollectEveryOccurrence) where

import Control.Monad (forM_)
import Data.Either (isLeft,isRight)
import Test.Hspec
import qualified LawSpec.Model as S
import qualified LawSpec.Core as C
import SourceRecordUnitFixtures
import qualified LawSpec.Frontend as Frontend
import LawSpec.Core.Eval (evaluateValueProposition)
import LawSpec.Core.Types (makeRegistry)
import LawSpec.Elaboration
import LawSpec.Core.RecordIdentity (internRecordDeclarations)
import LawSpec.Core.RecordNormalize (normalizeProgramRecords)
import LawSpec.Core.Validate (validateProgram)
import LawSpec.Core.Definitions (prepareDefinitions)
import LawSpec.Core.Value (Value(..))
import LawSpec.CoreEmit (emitPlan,targets)
import LawSpec.Testing (planTesting)
import LawSpec.Scalar (Scalar(..))

lower bits = elaborateDefinitionUnitWithRecords [] bits
program bits unit = do
  (closed,records) <- lower bits unit
  pure (C.Program bits records [closed])
admit bits unit = either (Left . show) Right . normalizeProgramRecords =<< program bits unit
checked bits unit = do
  candidate <- admit bits unit
  either (Left . show) (const (Right candidate)) (validateProgram candidate)

-- Collection returns typed syntax; program validation remains mandatory.
test_recordUnitsCollectEveryOccurrence = describe "source record unit collection" $ do
  it "collects signatures, parameters and bodies and executes checked calls" $
    forM_ [32,64] $ \bits -> case checked bits source of
      Left message -> expectationFailure message
      Right candidate -> do
        fmap (length . snd) (lower bits source) `shouldSatisfy` either (const False) (> 1)
        case prepareDefinitions candidate of
          Left diagnostics -> expectationFailure (show diagnostics)
          Right invoke -> invoke (C.Id "record.unit::run") [] `shouldBe`
            Right (ScalarValue (SInteger "Integer" 7))
        case internRecordDeclarations (C.programDataDeclarations candidate) of
          Left message -> expectationFailure message
          Right unique -> length unique `shouldBe` 1
  it "uses collected declarations in the public frontend and checked law calls" $
    forM_ [32,64] $ \bits -> do
      case sourceRecordUnitProgram bits of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right candidate -> do
          length (C.programDataDeclarations candidate) `shouldSatisfy` (> 1)
          case (makeRegistry (C.programDataDeclarations candidate),prepareDefinitions candidate) of
            (Right registry,Right invoke) -> forM_ (concatMap C.unitProperties (C.programUnits candidate)) $ \law ->
              evaluateValueProposition registry bits invoke [] (C.propertyBody law) `shouldBe` Right True
            other -> expectationFailure "checked frontend program did not admit"
  it "collects leading and nested record quantifier types" $ do
    let input=S.Input "item" "_item" shape []
        value=get "count" (S.Var "_item")
        equality=S.AssertEqual value value
        outer=claim "outer" [input] equality
        nested=claim "nested" [] (S.AssertQuantified S.ForEvery input equality)
    case Frontend.elaborate 64 [base] [outer,nested] of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right candidate -> do
        validateProgram candidate `shouldBe` Right ()
        length (C.programDataDeclarations candidate) `shouldBe` 1
  it "retains products introduced only by an example expectation" $ do
    let property=claim "example" [] (S.AssertEqual (S.Number 1) (S.Number 1))
        actual=get "count" (literal 3)
        ex=S.Example "projected record" [] [S.Expectation actual (S.IntLiteral 3)]
        withExample=property{S.original=(S.original property){S.examples=[ex]}}
    case Frontend.elaborate 64 [base] [withExample] of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right candidate -> do
        length (C.programDataDeclarations candidate) `shouldBe` 1
        case (makeRegistry (C.programDataDeclarations candidate),prepareDefinitions candidate) of
          (Right registry,Right invoke) -> do
            let example=head (C.propertyExamples (head (C.unitProperties (head (C.programUnits candidate)))))
            forM_ (C.exampleExpectations example) $ \expectation ->
              evaluateValueProposition registry 64 invoke [] expectation `shouldBe` Right True
          _ -> expectationFailure "example context did not admit"
  it "collects products in resource acquisition, release and reset expressions" $ do
    let property=claim "allocation" [] (S.AssertEqual (get "count" (S.Var "allocation")) (S.Number 7))
        original=(S.original property){S.lawResources=[("allocation",shape)]}
        ready=get "ready" (S.RecordLit [("ready",S.BoolLit True)])
        resource=S.ResourceDeclaration shape (literal 7) ("allocation",ready) (Just ("allocation",ready)) range False
        unit=base{S.resourceDeclarations=[resource]}
    case Frontend.elaborate 64 [unit] [property{S.original=original}] of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right candidate -> do
        validateProgram candidate `shouldBe` Right ()
        length (C.programDataDeclarations candidate) `shouldBe` 2
        let resource=head (C.propertyResources (head (C.unitProperties (head (C.programUnits candidate)))))
        C.resourceReset resource `shouldSatisfy` maybe False (const True)
  it "audits duplicate signature occurrences before sharing their identity" $ do
    let field name=S.RecordField name name
        denominator=field "denominator" integer
        guard=field "guard" (S.Refined "b" boolean (Just (S.Binary "!=" (S.Var "denominator") (S.Number 0))))
        amount=field "amount" (S.Refined "n" integer (Just
          (S.Binary ">" (S.Binary "/" (S.Var "n") (S.Var "denominator")) (S.Number 0))))
        good=S.Record [denominator,guard,amount]
        bad=S.Record [denominator,amount,guard]
        unit=base{S.functions=[("safe",good),("unsafe",bad)]}
    case lower 64 unit of
      Left message -> expectationFailure message
      Right (_,records) -> do
        length records `shouldBe` 2
        C.dataId (head records) `shouldBe` C.dataId (last records)
        validateProgram (C.Program 64 records []) `shouldSatisfy` isLeft
    Frontend.elaborate 64 [unit] [] `shouldSatisfy` isLeft
  it "retains mandatory restriction rejection in the public frontend" $ do
    let unit n=base {S.functions=[("create",positive)],S.functionDefinitions=
          [definition "create" [] positive (literal n)]}
    Frontend.elaborate 64 [unit 1] [] `shouldSatisfy` isRight
    Frontend.elaborate 64 [unit 0] [] `shouldSatisfy` isLeft
  it "collects a product introduced only inside an inferred body" $ do
    let unit = base {S.functions=[("run",integer)],S.functionDefinitions=
          [definition "run" [] integer (get "count" (literal 9))]}
    checked 64 unit `shouldSatisfy` isRight
    fmap (length . snd) (lower 64 unit) `shouldSatisfy` either (const False) (> 0)
  it "rejects violated intrinsic restrictions during mandatory admission" $ do
    let unit n = base {S.functions=[("create",positive)],S.functionDefinitions=
          [definition "create" [] positive (literal n)]}
    checked 64 (unit 1) `shouldSatisfy` isRight
    checked 64 (unit 0) `shouldSatisfy` isLeft
  it "does not lose undefined unselected fields behind a projection" $ do
    let body=get "count" (S.RecordLit [("count",S.Number 7),
          ("unused",S.Binary "/" (S.Number 1) (S.Number 0))])
        unit=base {S.functions=[("run",integer)],S.functionDefinitions=[definition "run" [] integer body]}
    checked 64 unit `shouldSatisfy` isLeft
  it "retains records introduced inside a contract's terms" $ do
    let contract=S.Contract "count" [("item",shape)] ("result",integer) []
          [S.Binary "==" (S.Var "result") (get "count" (S.Var "item")),
           S.Binary "==" (get "count" (literal 3)) (S.Number 3)]
        unit=source {S.contracts=[contract]}
    case lower 64 unit of
      Left message -> expectationFailure message
      Right (closed,records) -> do
        length (C.unitContracts closed) `shouldBe` 1
        length records `shouldSatisfy` (> 1)
    checked 64 unit `shouldSatisfy` isRight
  it "collects a standalone adapter contract without dropping its declarations" $ do
    let contract=S.Contract "adapter" [("item",shape)] ("result",integer)
          [S.Binary ">=" (get "count" (S.Var "item")) (S.Number 0)] []
    case elaborateContractWithRecords [] 64 base contract of
      Left message -> expectationFailure message
      Right (closed,records) -> do
        length records `shouldSatisfy` (> 0)
        validateProgram (C.Program 64 records [C.Unit (C.Id "record.unit")
          [C.Declaration (C.Id "record.unit::adapter") "adapter"
            (C.Arrow (C.binderType (head (C.contractArguments closed)))
            (C.binderType (C.contractResult closed))) (C.GeneratedFrom (C.Id "record.unit"))]
          [closed] [] [] []]) `shouldBe` Right ()
  it "collects session and mailbox products while retaining session references" $ do
    let unit=base {S.protocols=[S.Protocol "Payload" [S.Send shape,S.Receive shape] range,
          S.Protocol "Forward" [S.Send (S.Named "Payload")] range],
          S.mailboxes=[("items",shape,range)]}
    case lower 64 unit of
      Left message -> expectationFailure message
      Right (closed,records) -> do
        length records `shouldBe` 3
        C.sessionSteps (last (C.unitSessions closed)) `shouldBe`
          [(True,C.Constructor "record.unit::session::Payload" [])]
        validateProgram (C.Program 64 records [closed]) `shouldBe` Right ()
  it "collects ability parameters, operations, failures, resources and handler state" $ do
    let ability=S.AbilityDeclaration "Store" ["a"] [("read",S.Variable "a")] [] range "" [("read",shape)] (Just shape)
        abilityType=S.Applied "Store" shape
        handler=S.HandlerDeclaration "store" abilityType (Just ("state",shape,literal 5)) [] range "" []
        unit=base {S.abilities=[ability],S.handlerDeclarations=[handler]}
    case lower 64 unit of
      Left message -> expectationFailure message
      Right (closed,records) -> do
        length records `shouldSatisfy` (>= 5)
        let stored=head (C.unitAbilities closed)
        C.abilityRefArguments (C.abilityInstance stored) `shouldBe`
          [snd (head (C.abilityOperations stored))]
        C.abilityFailures stored `shouldBe` [("read",C.AbilityRef C.failAbilityId
          [snd (head (C.abilityOperations stored))])]
        C.abilityResource stored `shouldBe` Just (snd (head (C.abilityOperations stored)))
        fmap fst (C.handlerState (head (C.unitHandlers closed))) `shouldBe` C.abilityResource stored
  it "keeps the expression-only unit and contract APIs from silently dropping records" $ do
    elaborateDefinitionUnit [] 64 source `shouldSatisfy` isLeft
    elaborateContract [] 64 base (S.Contract "adapter" [("item",shape)] ("result",integer) [] [])
      `shouldSatisfy` isLeft
  it "permits the old API with registered descriptors after auditing occurrences" $
    case coreTypeWithRecords [] 64 shape of
      Left message -> expectationFailure message
      Right (_,records) -> elaborateDefinitionUnit records 64 source `shouldSatisfy` isRight
  it "emits the admitted implementation plane on every target" $
    case checked 64 source >>= either (Left . show) Right . planTesting of
      Left message -> expectationFailure message
      Right plan -> forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight
