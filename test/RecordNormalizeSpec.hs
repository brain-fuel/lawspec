-- | Structural identity must survive specialization through complete programs,
-- with every constructor contract still admitted before declaration sharing.
-- ref:DEC-typed-core-boundary ref:DEC-total-definitions
module RecordNormalizeSpec (test_recordNormalizationPreservesPrograms) where

import Control.Monad (forM_)
import Data.Either (isLeft,isRight)
import Data.List (isInfixOf)
import Test.Hspec
import LawSpec.Common
import LawSpec.Core
import LawSpec.Core.RecordIdentity
import LawSpec.Core.RecordNormalize
import LawSpec.Core.Types (makeRegistry)
import LawSpec.Core.Validate (validateProgram)
import LawSpec.Core.Definitions (prepareDefinitions)
import LawSpec.Core.Eval (evaluateValueProposition)
import LawSpec.CoreEmit (emitPlan,targets)
import qualified LawSpec.Core.Verification as V
import qualified LawSpec.Testing as Testing
import LawSpec.Scalar
import RecordIdentityFixtures

origin :: Origin
origin=GeneratedFrom (Id "normalization")
integerType,boolean :: Type
integerType=scalarType "Integer"
boolean=scalarType "Bool"
number :: Integer -> Expr
number n=Expr integerType (Constant (SInteger "Integer" n)) origin
local :: Binder -> Expr
local b=Expr (binderType b) (Local (binderId b)) origin
field :: String -> Type -> RecordField
field name wanted=RecordField (Binder (Id ("field::"++name)) name wanted) []
make :: [Id] -> [RecordField] -> DataDeclaration
make parameters fields=fst (either error id (makeRecordDeclaration parameters fields origin))
comparison :: BinaryOp -> Expr -> Expr -> Expr
comparison operation a b=Expr boolean (Binary operation (Numeric (expressionType a)) a b) origin

test_recordNormalizationPreservesPrograms :: Spec
test_recordNormalizationPreservesPrograms=describe "structural record normalization" $ do
  it "makes generic and concrete records interoperate through checked functions and nested nominal payloads" $
    forM_ [32,64] $ \bits -> do
      let source=recordInteroperabilityProgram bits
      validateProgram source `shouldSatisfy` isLeft
      case normalizeProgramRecords source of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right normalized -> do
          validateProgram normalized `shouldBe` Right ()
          let registry=either error id (makeRegistry (programDataDeclarations normalized))
              invoke=either (error.show) id (prepareDefinitions normalized)
          forM_ [p | u<-programUnits normalized,p<-unitProperties u] $ \p ->
            evaluateValueProposition registry bits invoke [] (propertyBody p) `shouldBe` Right True
  it "normalizes before native planning and emits every interoperating program on all targets" $
    forM_ [32,64] $ \bits -> case Testing.planTesting (recordInteroperabilityProgram bits) of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right plan -> do
        length (Testing.planDataDeclarations plan) `shouldBe` 7
        forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight
  it "is idempotent for nested templates and concrete instances" $ do
    let once=normalizeProgramRecords (recordInteroperabilityProgram 64)
    once `shouldSatisfy` isRight
    (once >>= normalizeProgramRecords) `shouldBe` once
  it "does not erase malformed record identity matches" $ do
    let declaration=make [] [field "value" integerType]
        wanted=scalarType (idText (dataId declaration))
        constructor=head (dataConstructors declaration)
        value=either error id (constructRecord (Id "malformed") declaration [] [("value",number 7)] origin)
        badField=Binder (Id "bad.match.field") "value" boolean
        badLocal=local badField
        rebuilt=Expr wanted (Construct (constructorId constructor) [badLocal]) origin
        bad=Expr wanted (Match value [MatchCase (constructorId constructor) [badField] rebuilt]) origin
        signature=Declaration (Id "bad.identity") "identity" wanted origin
        program=Program 64 [declaration] [Unit (Id "bad") [signature] [] [] [Definition signature [] bad] []]
    case normalizeProgramRecords program of
      Left _ -> pure ()
      Right normalized -> validateProgram normalized `shouldSatisfy` isLeft
  it "retains every duplicate occurrence's definedness audit after normalization" $ do
    let x=field "z" integerType; y=field "a" integerType
        nonzero=comparison NotEqual (local (recordFieldBinder x)) (number 0)
        divided=Expr integerType (Binary Quotient (Numeric integerType) (number 1) (local (recordFieldBinder x))) origin
        positive=comparison Greater divided (number 0)
        good=make [] [x{recordFieldPredicates=[nonzero]},y{recordFieldPredicates=[positive]}]
        bad=make [] [y{recordFieldPredicates=[positive]},x{recordFieldPredicates=[nonzero]}]
    normalizeProgramRecords (Program 64 [good] []) `shouldSatisfy` isRight
    case normalizeProgramRecords (Program 64 [good,good] []) of
      Right result -> length (programDataDeclarations result) `shouldBe` 1
      Left diagnostics -> expectationFailure (show diagnostics)
    forM_ [[good,bad],[bad,good]] $ \declarations -> do
      let source=Program 64 declarations []
      case normalizeProgramRecords source of
        Left diagnostics -> any (isInfixOf "nonzero" . message) diagnostics `shouldBe` True
        Right _ -> expectationFailure "an unsafe source order escaped constructor admission"
      Testing.planTestingWith V.noVerification source `shouldSatisfy` isLeft
  it "admits equivalent safe predicate orders in a shared constructor environment" $ do
    let x=field "x" integerType; y=field "y" integerType
        positive f=f{recordFieldPredicates=[comparison Greater (local (recordFieldBinder f)) (number 0)]}
        first=make [] [positive x,positive y]
        second=make [] [positive y,positive x]
        own=field "own" (scalarType (idText (dataId first)))
        selected=Binder (Id "dependent::match::x") "x" integerType
        other=Binder (Id "dependent::match::y") "y" integerType
        quotient=Expr integerType (Binary Quotient (Numeric integerType) (number 1) (local selected)) origin
        condition=Expr boolean (Match (local (recordFieldBinder own))
          [MatchCase (constructorId (head (dataConstructors first))) [selected,other]
            (comparison Greater quotient (number 0))]) origin
        dependent=make [] [own{recordFieldPredicates=[condition]}]
    dataId first `shouldBe` dataId second
    forM_ [[first,second,dependent],[second,first,dependent]] $ \declarations ->
      case normalizeProgramRecords (Program 64 declarations []) of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right normalized -> length (programDataDeclarations normalized) `shouldBe` 2
  it "keeps constructor origins and predicate spans distinct from the declaration origin" $ do
    let x=field "value" integerType
        range=Span (Location "record.lawspec" 3 5) (Location "record.lawspec" 3 25)
        predicate=(comparison Greater (local (recordFieldBinder x)) (number 0)){expressionOrigin=SourceSpan range}
        original=make [] [x{recordFieldPredicates=[predicate]}]
        marked=original{dataConstructors=[c{constructorOrigin=SourceSpan range} | c<-dataConstructors original]}
    case normalizeProgramRecords (Program 64 [marked] []) of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right normalized -> do
        let declaration=head (programDataDeclarations normalized)
            constructor=head (dataConstructors declaration)
        dataOrigin declaration `shouldBe` origin
        constructorOrigin constructor `shouldBe` SourceSpan range
        map expressionOrigin (constructorPredicates constructor) `shouldBe` [SourceSpan range]
  it "does not unwrap nominal products with matching structural fields" $ do
    let anonymous=make [] [field "value" integerType]
        anonymousType=scalarType (idText (dataId anonymous))
        nominalType=scalarType "nominal::type::Amount"
        nominal=DataDeclaration (Id "nominal::type::Amount") "Amount" []
          [DataConstructor (Id "nominal::type::Amount::Amount") "Amount"
            [Binder (Id "amount.value") "value" integerType] [] origin [] []] origin Nothing
        argument=Binder (Id "read::input::0") "amount" nominalType
        signature=Declaration (Id "read") "read" (Arrow nominalType anonymousType) origin
        wrong=Definition signature [argument] ((local argument){expressionType=nominalType})
        source=Program 64 [anonymous,nominal] [Unit (Id "nominal") [signature] [] [] [wrong] []]
    Testing.planTesting source `shouldSatisfy` isLeft
  it "retains intrinsic definedness and termination with all law layers unselected" $ do
    let source=recordInteroperabilityProgram 64
        first=head (programUnits source)
        signature=Declaration (Id "bad") "bad" (Arrow integerType integerType) origin
        argument=Binder (Id "bad::input::0") "value" integerType
        divided=Expr integerType (Binary Quotient (Numeric integerType) (local argument) (number 0)) origin
        recursive=Expr integerType (ExternalCall (Id "bad") [local argument]) origin
    forM_ [divided,recursive] $ \body -> do
      let bad=Definition signature [argument] body
          modified=source{programUnits=[first{unitDeclarations=signature:unitDeclarations first,
            unitDefinitions=bad:unitDefinitions first}]}
      Testing.planTestingWith V.noVerification modified `shouldSatisfy` isLeft
  it "discovers instances used only in benchmark expressions and session or mailbox types" $ do
    let parameter=Id "a"
        generic=make [parameter] [field "value" (TypeVariable parameter)]
        concrete=make [] [field "value" integerType]
        before=Constructor (idText (dataId generic)) [TypeArgument integerType]
        after=scalarType (idText (dataId concrete))
        value=either error id (constructRecord (Id "benchmark") generic [integerType] [("value",number 7)] origin)
        settings=UnitHarness "measure" False False [] [("record",value)]
        source=Program 64 [generic] [(Unit (Id "interfaces") [] [] [] [] [])
          {unitSessions=[Session (Id "channel") "channel" [(True,before)]],
           unitMailboxes=[Mailbox "jobs" before],unitHarnessSettings=Just settings}]
    case normalizeProgramRecords source of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right normalized -> do
        let u=head (programUnits normalized)
        after `shouldSatisfy` (\wanted -> any ((==wanted) . scalarType . idText . dataId) (programDataDeclarations normalized))
        map sessionSteps (unitSessions u) `shouldBe` [[(True,after)]]
        map mailboxType (unitMailboxes u) `shouldBe` [after]
        fmap (map (expressionType.snd) . harnessBenchmarks) (unitHarnessSettings u) `shouldBe` Just [after]
  it "retargets effects, handler state and failure bindings without changing their identities" $ do
    let parameter=Id "a"
        generic=make [parameter] [field "value" (TypeVariable parameter)]
        concrete=make [] [field "value" integerType]
        before=Constructor (idText (dataId generic)) [TypeArgument integerType]
        after=scalarType (idText (dataId concrete))
        value=either error id (constructRecord (Id "state") generic [integerType] [("value",number 7)] origin)
        ref=AbilityRef (Id "State") [before]
        a=Ability (Id "State") "State" [Id "state.parameter"] [("get",Arrow before before)] origin [before] Nothing [("get",failAbilityRef)] (Just before)
        failAbilityRef=AbilityRef failAbilityId [before]
        h=Handler (Id "handler") "handler" ref [] (Just (before,value)) origin [failAbilityRef]
        perform=Expr before (Perform (Operation ref "get") [value]) origin
        signature=(Declaration (Id "operation") "operation" before origin){declarationUses=[ref]}
        d=Definition signature [] perform
        binding=FailureBinding ["NativeError"] (constructorId (head (dataConstructors generic))) before True
        source=Program 64 [generic] [(Unit (Id "effects") [signature] [] [] [d] [])
          {unitAbilities=[a],unitHandlers=[h],unitFailureBindings=[binding]}]
    case normalizeProgramRecords source of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right normalized -> do
        let u=head (programUnits normalized); a'=head (unitAbilities u); h'=head (unitHandlers u)
            binding'=head (unitFailureBindings u); d'=head (unitDefinitions u)
        abilityId a' `shouldBe` abilityId a
        abilityArguments a' `shouldBe` [after]
        abilityOperations a' `shouldBe` [("get",Arrow after after)]
        abilityResource a' `shouldBe` Just after
        map (abilityRefArguments.snd) (abilityFailures a') `shouldBe` [[after]]
        handlerId h' `shouldBe` handlerId h
        fmap (\(wanted,expression) -> (wanted,expressionType expression)) (handlerState h') `shouldBe` Just (after,after)
        failureType binding' `shouldBe` after
        failureConstructor binding' `shouldBe` constructorId (head (dataConstructors concrete))
        case expressionNode (definitionBody d') of
          Perform (Operation (AbilityRef identity arguments) "get") [result] -> do
            identity `shouldBe` Id "State"
            arguments `shouldBe` [after]
            expressionType result `shouldBe` after
          other -> expectationFailure (show other)
  it "keeps scoped witnesses, strategy binds, resources and data-only examples typed together" $ do
    let parameter=Id "a"
        generic=make [parameter] [field "value" (TypeVariable parameter)]
        concrete=make [] [field "value" integerType]
        before=Constructor (idText (dataId generic)) [TypeArgument integerType]
        after=scalarType (idText (dataId concrete))
        payload=either error id (constructRecord (Id "coverage") generic [integerType] [("value",number 7)] origin)
        original=Binder (Id "law::input::0") "original" before
        selected=Binder (Id "law::logical::0") "selected" before
        resource=Binder (Id "law::resource::0") "snapshot" before
        seed=Binder (Id "strategy::let::seed") "seed" before
        filtered=Binder (Id "strategy::let::filtered") "filtered" before
        aimed=Binder (Id "strategy::input::aim") "aim" before
        dataEqual a b=Expr boolean (Binary Equal (Structural before) a b) origin
        aim=Quantifier aimed [dataEqual (local aimed) payload] []
        strategy=DrawBind seed (DrawOneOf before [payload]) (DrawFrequency
          [(1,DrawSuchThat (DrawOneOf before [local seed]) filtered (dataEqual (local filtered) (local seed)) 20),
           (1,DrawAny before (Just aim))])
        labelBound=Binder (Id "label::let::record") "record" before
        label=Expr (scalarType "Text") (Let labelBound payload (Expr (scalarType "Text") (Constant (textScalar "record")) origin)) origin
        metric=Expr integerType (Let labelBound payload (number 0)) origin
        release=Expr (scalarType "Unit") (Let labelBound (local resource) (Expr (scalarType "Unit") (Constant (SAbsent "Unit")) origin)) origin
        example=Example "record value" [(binderId original,payload)] [Equation (Structural before) (local original) payload]
        h=noHarness{harnessCover=[Cover 10 "record" (dataEqual (local original) payload)],
          harnessClassify=[(dataEqual (local original) payload,"record")],harnessLabels=[label],harnessTarget=Just metric,
          harnessDraws=[(binderId original,"records",strategy)],
          harnessSearches=[(binderId selected,["original","selected"],"records",strategy)],
          harnessWitnesses=[WitnessChoice (binderId selected) ["original","selected"] (local original)]}
        p=Property (Id "law") "find matching record" (Location "records" 1 1)
          [Quantifier original [] []]
          (Quantified ForSome (Quantifier selected [] []) (Equation (Structural before) (local selected) (local original)))
          [example] defaultGeneration "" "" [] [] [] [Resource resource payload release (Just release) Nothing False]
          h UniversalDomain emptyLawMetadata
        source=Program 64 [generic] [Unit (Id "coverage") [] [] [p] [] []]
    case normalizeProgramRecords source of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right normalized -> do
        validateProgram normalized `shouldBe` Right ()
        let p'=head (unitProperties (head (programUnits normalized)))
            h'=propertyHarness p'
        map (binderType.quantifiedBinder) (propertyInputs p') `shouldBe` [after]
        map (expressionType.witnessValue) (harnessWitnesses h') `shouldBe` [after]
        map (map (expressionType.snd).exampleBindings) (propertyExamples p') `shouldBe` [[after]]
        map (binderType.resourceBinder) (propertyResources p') `shouldBe` [after]
        case harnessSearches h' of
          [(_,_,_,DrawBind bound (DrawOneOf wanted _) (DrawFrequency [(_,DrawSuchThat _ filterBinder _ _),(_,DrawAny anyType (Just q))]))] -> do
            map binderType [bound,filterBinder,quantifiedBinder q] `shouldBe` replicate 3 after
            [wanted,anyType] `shouldBe` [after,after]
          other -> expectationFailure (show other)
        Testing.planTesting source `shouldSatisfy` isRight
  it "accepts only closed data bindings as concrete record fixtures" $ do
    let record=make [] [field "value" integerType]
        literal=either error id (constructRecord (Id "fixture") record [] [("value",number 7)] origin)
        bound=Binder (Id "bound") "bound" integerType
        computed=Expr integerType (Binary Add (Numeric integerType) (number 1) (number 2)) origin
        adapter=Expr integerType (ExternalCall (Id "adapter") []) origin
        expression value body=Expr (expressionType body) (Let bound value body) origin
    isConcrete literal `shouldBe` True
    isConcrete (expression (number 7) (local bound)) `shouldBe` True
    forM_ [expression computed (local bound),expression adapter (number 7),local bound,
      expression (local bound) (local bound)] $ \value -> isConcrete value `shouldBe` False
