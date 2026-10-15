-- | Harness collection retains declarations, purity, lexical scope and honest
-- witness evidence. ref:REQ-harness ref:DEC-typed-core-boundary
module SourceRecordHarnessSpec (test_recordHarnessesUseOneTypedContext) where

import Control.Monad (forM_)
import Data.Either (isLeft,isRight)
import Data.List (isInfixOf)
import Test.Hspec
import qualified LawSpec.Model as S
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Search as Search
import qualified LawSpec.Core.Verification as V
import LawSpec.Core.Types (makeRegistry)
import LawSpec.Core.Validate (validateProgram)
import LawSpec.Core.Definitions (prepareDefinitions)
import LawSpec.Core.Eval (evaluateValue)
import LawSpec.Core.Value (Value(..))
import LawSpec.Core.Evidence (Obligation(..),Status(..))
import LawSpec.Discharge (dischargeEvidenceWith)
import LawSpec.Frontend (elaborate)
import LawSpec.Testing (planTesting)
import LawSpec.CoreEmit (emitPlan,targets)
import LawSpec.Scalar (Scalar(..))
import SourceRecordHarnessFixtures
import SourceRecordUnitFixtures (base,integer,boolean,get,claim,definition)

properties = concatMap C.unitProperties . C.programUnits
checked result action = either (expectationFailure . show) action result
statuses layers candidate = map obligationStatus . filter ((=="law") . obligationStage) <$>
  dischargeEvidenceWith (V.Verification layers) candidate
compileWith property settings = elaborate 64 [base{S.unitHarness=Just harness,S.lawHarness=[(S.name property,settings)]}] [property]
scopedDraw candidate = case C.harnessSearches (C.propertyHarness (head (properties candidate))) of
  [(_,_,_,draw)] -> draw
  _ -> error "expected one scoped strategy"
candidates candidate draw = do
  registry <- makeRegistry (C.programDataDeclarations candidate)
  invoke <- either (Left . show) Right (prepareDefinitions candidate)
  values <- Search.strategyCandidates 10 (\_ _ -> Left "unexpected default pool") draw
  let origin=C.GeneratedFrom (C.Id "harness.probe")
      rejected=C.Expr (C.scalarType "Bool") (C.Constant (SBool False)) origin
  mapM (\value -> evaluateValue registry 64 invoke [] (Search.applyCandidate value id rejected)) values

test_recordHarnessesUseOneTypedContext = describe "source record harness collection" $ do
  it "collects observations, witnesses, dependent draws and benchmarks in the public frontend" $
    forM_ [32,64] $ \bits -> checked (sourceRecordHarnessProgram bits) $ \candidate -> do
      validateProgram candidate `shouldBe` Right ()
      length (properties candidate) `shouldBe` 4
      length (C.programDataDeclarations candidate) `shouldSatisfy` (>= 7)
      statuses [V.Exhaustive] candidate `shouldBe` Right (Incomplete:replicate 3 ExhaustivelyChecked)
      case planTesting candidate of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right testing -> forM_ targets $ \target -> emitPlan target testing `shouldSatisfy` isRight
  it "does not change obligations or mark unselected laws verified" $
    checked (compileWith recordLaw scoped) $ \withPlan ->
      checked (compileWith recordLaw plan) $ \withoutPlan -> do
        map C.propertyBody (properties withPlan) `shouldBe` map C.propertyBody (properties withoutPlan)
        statuses [] withPlan `shouldBe` Right [NotVerified]
  it "evaluates record-valued scoped strategy candidates in their typed registry" $
    checked (compileWith recordLaw scoped) $ \candidate -> do
      case candidates candidate (scopedDraw candidate) of
        Left message -> expectationFailure message
        Right values -> length values `shouldBe` 2
      statuses [V.Exhaustive] candidate `shouldBe` Right [ExhaustivelyChecked]
  it "keeps a bounded record miss inconclusive instead of proving nonexistence" $ do
    let miss=scoped{S.planDraws=[("answer","requests",requested,S.GenOneOf [number "requested" (S.Number 6)])]}
        negative=recordLaw{S.assertion=S.AssertNot (S.assertion recordLaw)}
    forM_ [recordLaw,negative] $ \property -> checked (compileWith property miss) $ \candidate ->
      statuses [V.Exhaustive] candidate `shouldBe` Right [Incomplete]
  it "resolves a local generator record before a function of the same name" $ do
    let shadow=plan{S.planDraws=[("answer","local",integer,S.GenBind "payload" selected
          (S.GenOneOf [number "selected" (S.Number 7)]) (S.GenOneOf [get "selected" (S.Var "payload")]))]}
        unit=base{S.functions=[("payload",S.Arrow boolean boolean)],S.unitHarness=Just harness,
          S.lawHarness=[(S.name dependentLaw,shadow)]}
    checked (elaborate 64 [unit] [dependentLaw]) $ \candidate -> do
      candidates candidate (scopedDraw candidate) `shouldBe` Right [ScalarValue (SInteger "Integer" 7)]
      statuses [V.Exhaustive] candidate `shouldBe` Right [ExhaustivelyChecked]
  it "keeps the nearest generator binder when nested binds repeat a name" $ do
    let boolRecord=record [("flag",boolean)]
        shadow=plan{S.planDraws=[("answer","local",integer,S.GenBind "payload" boolRecord
          (S.GenOneOf [S.RecordLit [("flag",S.BoolLit True)]])
          (S.GenBind "payload" selected (S.GenOneOf [number "selected" (S.Number 7)])
            (S.GenOneOf [get "selected" (S.Var "payload")])))]}
    checked (compileWith dependentLaw shadow) $ \candidate ->
      candidates candidate (scopedDraw candidate) `shouldBe` Right [ScalarValue (SInteger "Integer" 7)]
  it "rejects native computations hidden in unused record fields of observations" $ do
    let expression=get "safe" (S.RecordLit [("safe",S.BoolLit True),("hidden",S.Var "nativeValue")])
        bad=plan{S.planCover=[(0,"unsafe",expression)]}
        unit=base{S.functions=[("nativeValue",boolean)],S.unitHarness=Just harness,S.lawHarness=[(S.name reflexive,bad)]}
    elaborate 64 [unit] [reflexive] `shouldSatisfy` either
      (any (isInfixOf "not a checked definition" . S.message)) (const False)
  it "reports bad record witnesses and draws at their harness source" $ do
    let badWitness=constructive{S.planResolvedWitnesses=[S.HarnessWitness ["flag","answer"] answerInput
          [flagInput] (get "absent" (number "witness" (S.Number 7))) range]}
        badDraw=dependent{S.planDraws=[("answer","bad",integer,S.GenOneOf
          [get "absent" (number "requested" (S.Number 7))])]}
    forM_ [(witnessLaw,badWitness),(dependentLaw,badDraw)] $ \(property,settings) ->
      case compileWith property settings of
        Left diagnostics -> do
          map S.code diagnostics `shouldBe` ["harness"]
          map S.at diagnostics `shouldBe` [Just (S.spanStart range)]
        Right _ -> expectationFailure "invalid harness record expression was accepted"
  it "collects named and filtered record strategies without capturing caller locals" $ do
    let filtered=S.StrategyDeclaration "requests" (S.Refined "request" requested (Just
          (S.Binary ">" (get "requested" (S.Var "request")) (S.Number 0))))
          (S.GenFrequency [(1,S.GenOneOf [number "requested" (S.Number 7)])]) range
        settings=scoped{S.planDraws=[("answer","named",requested,S.GenNamed "requests")]}
        unit=base{S.unitHarness=Just harness{S.harnessItems=[S.HarnessStrategy filtered]},
          S.lawHarness=[(S.name recordLaw,settings)]}
    checked (elaborate 64 [unit] [recordLaw]) $ \candidate ->
      statuses [V.Exhaustive] candidate `shouldBe` Right [ExhaustivelyChecked]
  it "keeps intrinsic constructor admission outside law-verification selection" $ do
    let field name=S.RecordField name name
        denominator=field "denominator" integer
        guard=field "guard" (S.Refined "b" boolean (Just (S.Binary "!=" (S.Var "denominator") (S.Number 0))))
        amount=field "amount" (S.Refined "n" integer (Just
          (S.Binary ">" (S.Binary "/" (S.Var "n") (S.Var "denominator")) (S.Number 0))))
        expression fields=get "amount" (S.Annotate (S.RecordLit
          [("denominator",S.Number 1),("guard",S.BoolLit True),("amount",S.Number 7)]) (S.Record fields))
        settings fields=constructive{S.planResolvedWitnesses=[S.HarnessWitness ["flag","answer"] answerInput
          [flagInput] (expression fields) range]}
    checked (compileWith witnessLaw (settings [denominator,guard,amount])) $ \candidate ->
      statuses [] candidate `shouldBe` Right [NotVerified]
    compileWith witnessLaw (settings [denominator,amount,guard]) `shouldSatisfy` isLeft
  it "reuses ordinary checked functions inside constructed witnesses" $ do
    let increment=S.Apply (S.Var "increment") (S.Binary "-" (wanted (S.Var "_flag")) (S.Number 1))
        settings=constructive{S.planResolvedWitnesses=[S.HarnessWitness ["flag","answer"] answerInput
          [flagInput] (get "witness" (number "witness" increment)) range]}
        unit=base{S.functions=[("increment",S.Arrow integer integer)],S.functionDefinitions=
          [definition "increment" [("n",integer)] integer (S.Binary "+" (S.Var "n") (S.Number 1))],
          S.unitHarness=Just harness,S.lawHarness=[(S.name witnessLaw,settings)]}
    checked (elaborate 64 [unit] [witnessLaw]) $ \candidate ->
      statuses [V.Exhaustive] candidate `shouldBe` Right [ExhaustivelyChecked]
  it "retains native benchmark dependencies and attributes benchmark errors" $ do
    let value=get "benchmark" (number "benchmark" (S.Var "nativeValue"))
        unit expression=base{S.functions=[("nativeValue",integer)],S.unitHarness=Just harness
          {S.harnessItems=[S.HarnessBenchmark "projection" expression range]}}
    elaborate 64 [unit value] [] `shouldSatisfy` isRight
    case elaborate 64 [unit (get "absent" (number "benchmark" (S.Number 9)))] [] of
      Left diagnostics -> do
        map S.code diagnostics `shouldBe` ["harness"]
        map S.at diagnostics `shouldBe` [Just (S.spanStart range)]
        map S.message diagnostics `shouldSatisfy` all (isInfixOf "benchmark `projection`")
      Right _ -> expectationFailure "an invalid benchmark projection was accepted"
  it "evaluates a record-only benchmark through the checked Core evaluator" $
    checked (sourceRecordHarnessProgram 64) $ \candidate -> do
      let benchmarks=concat [C.harnessBenchmarks settings | unit<-C.programUnits candidate,
            Just settings<-[C.unitHarnessSettings unit]]
      case (makeRegistry (C.programDataDeclarations candidate),prepareDefinitions candidate,benchmarks) of
        (Right registry,Right invoke,[(_,body)]) ->
          evaluateValue registry 64 invoke [] body `shouldBe` Right (ScalarValue (SInteger "Integer" 9))
        _ -> expectationFailure "missing collected benchmark"
