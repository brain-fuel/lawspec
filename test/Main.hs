-- | The compiler's Hspec suite. Each module's test is named for the property
-- it verifies and cites the requirement that property serves.
-- ref:DEC-tests-cite-requirements
module Main where
import qualified ArtifactTargetSpec
import qualified PrologTargetSpec
import qualified WitnessSpec
import qualified QuantifierDomainSpec
import qualified SearchSpec
import qualified NamedBlocksSpec
import qualified ParserDiagnosticsSpec
import qualified CanonicalSpec
import qualified CaseFoldSpec
import qualified ExactWideningSpec
import qualified MappingSpec
import qualified MatchWarningSpec
import qualified CanonicalPredicateFactsSpec
import qualified CanonicalMatcherSpec
import qualified CanonicalInterfaceSpec
import qualified ModelLayerSelectionSpec
import qualified ContextualSpec
import qualified RecordIdentitySpec
import qualified RecordNormalizeSpec
import qualified SourceRecordScopeSpec
import qualified SourceRecordInferenceSpec
import qualified ContainerRecordViewsSpec
import qualified SourceGadtIndicesSpec
import qualified SmtSpec
import qualified GroovyBridgeSpec
import qualified PythonBindingNamesSpec
import qualified SwiftReadableSpec
import qualified FieldDefinitionExpansionSpec
import qualified SourceGadtRefinementsSpec
import qualified SourceRecordPayloadSpec
import qualified SourceTupleSpec
import qualified SelectionAdmissionSpec
import qualified SourceRecordCanonicalSpec
import qualified SourceRecordHarnessSpec
import qualified SourceRecordUnitSpec
import qualified SourceRecordElaborationSpec
import Test.Hspec
import qualified NativeBindingSpec
import qualified NativeRequestSpec
import qualified GenericDefinitionSpec
import qualified DefinitionPredicateSpec
import qualified RefinementProofSpec
import qualified DefinitionContractProofSpec
import qualified DefinitionSchemeSpec
import qualified InferenceSchemeSpec
import qualified TotalSpec
import qualified SourceDataSpec
import qualified StructuralSpec
import qualified DocumentSpec
import qualified PayloadProofSpec
import qualified PayloadSpec
import qualified CoreSpec
import qualified IndexedSpec
import qualified DomainModelSpec
import qualified StatefulModelSpec
import qualified ScenarioSpec
import qualified TargetNamesSpec
import qualified TimeSpec
import qualified ImportSpec
import qualified DischargeSpec
import qualified AttestationSpec
import qualified ApiContractSpec
import qualified ExplainSpec
import qualified DataShapeSpec
import qualified GadtSpec
import qualified FlowSpec
import qualified CollectionsSpec
import qualified EqSetSpec
import qualified EqSetOperationsSpec
import qualified CanonicalCollectionsSpec
import qualified PreludeResolutionSpec
import qualified SourceSyntaxSpec
import qualified CapabilityScopeSpec
import qualified AsyncSpec
import qualified AbilitiesSpec
import qualified LawPrimitivesSpec
import qualified HarnessSpec
import qualified BuiltinsSpec
import qualified BoundsSpec
import qualified ECMAScriptSpec
import qualified ConditionalSpec
import qualified IncrementalSpec
import qualified TestManifestSpec
import qualified RailwaySpec
import qualified SessionsPythonSpec
import qualified TypedSpec
import qualified TemporalSpec
import qualified DistributionSpec
import qualified UnificationSpec
import qualified BeamSpec
import qualified DotNetSpec
import qualified LanguageGapsSpec
import qualified MatcherAdmissionSpec
import qualified OperationResultSpec
import qualified SmtFrozenSpec
import qualified CounterexampleSpec
import qualified SmtDataSpec
import qualified SmtRecursionSpec
import qualified SmtTextSpec
import qualified SmtNumericSpec
import qualified ModelCheckSpec
import qualified RefutedStatusSpec
import qualified LawAnalysisSpec
import qualified SchedulerSpec
import LawSpec.Compile
import LawSpec.Model
import qualified LawSpec.Domain as D
import LawSpec.Eval
import LawSpec.Emit hiding (targets)
import LawSpec.CoreEmit (targets)
import LawSpec.Scalar
import LawSpec.Parser (parseSource)
import Data.Either (isLeft, isRight)
import Data.List (isInfixOf)

source :: String -> Source
source body = Source "test.lawspec" ("unit test.codec\n\nf :: Int32 -> Text\ng :: Text -> Int32\n" ++ body ++ "\nend unit\n")
concrete :: String -> String
concrete d = "law \"|codec| is definition: " ++ d ++ " end definition end law\n"
main :: IO ()
main = hspec $ do
  ArtifactTargetSpec.test_artifactTargets
  PrologTargetSpec.test_prologEmitter
  NamedBlocksSpec.test_namedBlocks
  ParserDiagnosticsSpec.test_parserDiagnostics
  MappingSpec.test_typedMappings
  MatchWarningSpec.test_matchWarnings
  CanonicalPredicateFactsSpec.test_canonicalPredicateFacts
  CanonicalMatcherSpec.test_canonicalMatchers
  CanonicalInterfaceSpec.test_canonicalInterface
  ModelLayerSelectionSpec.test_modelLayerSelection
  EqSetSpec.test_eqOnlySetsPreserveMembershipAndIteration
  EqSetOperationsSpec.test_eqSetOperations
  CanonicalCollectionsSpec.test_canonicalCollections
  PreludeResolutionSpec.test_preludeResolution
  SourceSyntaxSpec.test_sourceSyntax
  CapabilityScopeSpec.test_capabilityScopes
  CanonicalSpec.test_canonicalAuthoringPreservesIntrinsicGuarantees
  CaseFoldSpec.test_caseFold
  ExactWideningSpec.test_exactWidening
  ContextualSpec.test_articlesPreserveOrdinaryNamesAndScope
  RecordIdentitySpec.test_recordIdentitiesPreserveSemantics
  RecordNormalizeSpec.test_recordNormalizationPreservesPrograms
  SourceRecordScopeSpec.test_recordTypeScopesPreserveDependencies
  SourceRecordInferenceSpec.test_recordInferencePreservesClosedShapes
  SourceRecordElaborationSpec.test_recordElaborationUsesCheckedCore
  SourceRecordUnitSpec.test_recordUnitsCollectEveryOccurrence
  SourceRecordHarnessSpec.test_recordHarnessesUseOneTypedContext
  ContainerRecordViewsSpec.test_containerRecordViews
  SourceGadtIndicesSpec.test_sourceGadtPayloadIndices
  SmtSpec.test_smtTasks
  GroovyBridgeSpec.test_groovyJavaBody
  PythonBindingNamesSpec.test_pythonBindingNames
  SwiftReadableSpec.test_swiftReadableOutput
  FieldDefinitionExpansionSpec.test_fieldDefinitionExpansion
  SourceGadtRefinementsSpec.test_sourceGadtRefinements
  SourceRecordPayloadSpec.test_structuralNominalPayloads
  SourceTupleSpec.test_positionalProducts
  SelectionAdmissionSpec.test_selectionAdmission
  SourceRecordCanonicalSpec.test_canonicalRecordsReachCheckedCore
  WitnessSpec.test_constructiveWitnessesPreserveScopedMeaning
  QuantifierDomainSpec.test_refinedIntegerDomainsAreComplete
  SearchSpec.test_boundedWitnessSearchPreservesEvidence
  BeamSpec.test_beamCodeUsesCheckedCoreAndNativeFrameworks
  BeamSpec.test_beamRunsTheLanguageGaps
  DotNetSpec.test_dotnetTargetsShareOneRuntime
  NativeBindingSpec.test_nativeBindingsResolveToOneUnambiguousIdentity
  NativeRequestSpec.test_nativeBindingRequestsAreValidatedAtTheirBoundary
  CoreSpec.test_typedCoreIsValidatedIndependentlyOfInference
  IndexedSpec.test_indexedFamiliesElaborateToErasedDataWithProvedIndices
  DomainModelSpec.test_wrappersAndWorkflowsElaborateToCheckedLaws
  StatefulModelSpec.test_statefulModelsElaborateFromTypestate
  ScenarioSpec.test_scenariosAreAcceptedOnlyWhenDeadlockAndRaceFree
  TargetNamesSpec.test_targetNamesNeverCollideWithKeywords
  TimeSpec.test_durationsAreExactAndPortable
  ImportSpec.test_importsResolveAcrossUnitsWithoutLeakingAdapters
  DischargeSpec.test_lawsAreDischargedWithHonestEvidence
  AttestationSpec.test_attestationReportsWhereTestsRanWithoutChangingEvidence
  ApiContractSpec.test_compilerApiAnswersEveryRequestByItsDocumentedContract
  ExplainSpec.test_explanationsWordOneTypedLawInEachRegister
  DataShapeSpec.test_dataTypesBecomeEachTargetsIdiomaticShape
  GadtSpec.test_gadtMatchesRefineTypesLocally
  FlowSpec.test_flowTypesThreadEachStateThroughItsCalls
  CollectionsSpec.test_collectionsAreTypedEvaluatedAndOrderedPortably
  AsyncSpec.test_asyncAdaptersAreMarkedReportedAndBoundToEachTargetsTask
  AbilitiesSpec.test_abilityLawsHoldForEveryLawfulHandler
  LanguageGapsSpec.test_languageGapsClose
  MatcherAdmissionSpec.test_matcherFactsAreKeptInAdmission
  OperationResultSpec.test_operationResultsAreCheckedWhereTheyAreUsed
  SmtFrozenSpec.test_smtV1IsFrozen
  CounterexampleSpec.test_counterexamplesAreConfirmedByTheEvaluator
  SmtDataSpec.test_smtDataTasks
  SmtRecursionSpec.test_smtRecursion
  SmtRecursionSpec.test_smtInduction
  SmtTextSpec.test_smtText
  SmtNumericSpec.test_smtNumbers
  ModelCheckSpec.test_modelChecking
  RefutedStatusSpec.test_refutedLawsAreReportedAndFail
  LawAnalysisSpec.test_lawSetsAreCheckedTogether
  LawPrimitivesSpec.test_lawPrimitivesCheckWhatTheyReadAs
  HarnessSpec.test_harnessesChangeHowLawsRunNeverWhatTheyMean
  BuiltinsSpec.test_builtInAbilitiesHaveLawfulDefaultHandlers
  BoundsSpec.test_generationStaysWithinRefinedBoundsOnEveryTarget
  ECMAScriptSpec.test_javascriptIsLaidOutAsPrettierLaysItOut
  ConditionalSpec.test_conditionalsAreCheckedBranchByBranch
  IncrementalSpec.test_incrementalCompilationGivesTheSameResultAsAFreshOne
  TestManifestSpec.test_testManifestNamesEveryLawsTestOnEachTarget
  RailwaySpec.test_railwayCombinatorsComposeResultsAsDocumented
  SessionsPythonSpec.test_pythonSessionEndsFollowTheirProtocol
  TemporalSpec.test_temporalPropositionsAndBudgetsAreCheckedOverTheClock
  DistributionSpec.test_distributionIsSecureByDefaultAndContentAddressed
  UnificationSpec.test_existingFeaturesAreAbilities
  PayloadSpec.test_payloadPredicatesTraverseRecursiveParametersScoped
  PayloadProofSpec.test_payloadGuaranteesTransferOnlyWhereTheyHold
  DocumentSpec.test_layoutEngineKeepsGeneratedCodeReadableAndUnchanged
  StructuralSpec.test_structuralTypesHaveOneRegistryAndNativeDeclarations
  SourceDataSpec.test_sourceDataRefinementsLowerThroughNestedTypes
  TotalSpec.test_checkedDefinitionsExecuteTotallyInCore
  InferenceSchemeSpec.test_declarationSchemesInstantiateFreshlyAtEachUse
  DefinitionSchemeSpec.test_definitionTemplatesAreAuditedBeforeSpecialization
  GenericDefinitionSpec.test_genericDefinitionsSpecializeWithProvedResults
  DefinitionPredicateSpec.test_closedDefinitionsServeAsCorePredicates
  RefinementProofSpec.test_refinementImplicationIsDecidedExactly
  DefinitionContractProofSpec.test_refinedDefinitionsAreAdmittedOnlyWithProvedContracts
  TypedSpec.test_typedDefinitionsRunNativeWithTheirMeaning
  SchedulerSpec.test_parallelStepsNeverShareWhatTheyClaim
  describe "compiler" $ do
    it "checks the bundled prelude" $ compile [] `shouldBe` Right ([],[])
    it "expands the exact scratch example" $ do
      s <- readFile "examples/specs/atoi_codec.lawspec"
      case compile [Source "codec.lawspec" s] of
        Left ds -> expectationFailure (show ds)
        Right (_, [e]) -> do
          map inputName (inputs e) `shouldBe` ["x"]
          prettyExpanded e `shouldBe` "for all (x :: Int32) => atoi (itoa (x)) = x end for all"
          length (trace e) `shouldBe` 3
        Right other -> expectationFailure (show other)
    it "expands equivalent with Text and Int32 results and inherited examples" $ do
      s <- readFile "examples/specs/equivalent.lawspec"
      case compile [Source "equivalent.lawspec" s] of
        Left ds -> expectationFailure (show ds)
        Right (_, es) -> do
          map prettyExpanded es `shouldBe`
            ["for all (x :: Int32) => render (x) = referenceRender (x) end for all",
             "for all (x :: Int32) => clamp (x) = referenceClamp (x) end for all"]
          map (map inputName . inputs) es `shouldBe` [["x"], ["x"]]
          map (length . examples . original) es `shouldBe` [2, 2]
    it "requires equality of the output type when wrapping equivalent" $ do
      let wrapper eq = Source "generic.lawspec" ("unit generic\nlaw \"|alternatives| (f :: a -> b) (g :: a -> b) requires Eq " ++ eq ++ " is definition: apply law \"|equivalent| f g end definition end law\nend unit\n")
      compile [wrapper "b"] `shouldSatisfy` isRight
      compile [wrapper "a"] `shouldSatisfy` isLeft
    it "rejects equivalent functions with different result types" $
      compile [Source "bad.lawspec" "unit bad\n\nf :: Int32 -> Text\ng :: Int32 -> Int32\nlaw \"|bad| is definition : apply law \"|equivalent| f g end definition end law\nend unit\n"] `shouldSatisfy` isLeft
    it "rejects equivalent functions with different input types" $
      compile [Source "bad.lawspec" "unit bad\n\nf :: Int32 -> Int32\ng :: Text -> Int32\nlaw \"|bad| is definition : apply law \"|equivalent| f g end definition end law\nend unit\n"] `shouldSatisfy` isLeft
    it "expands equivalent without capturing an implementation named x" $
      compile [Source "capture.lawspec" "unit capture\n\nx :: Int32 -> Text\ng :: Int32 -> Text\nlaw \"|ok| is definition : apply law \"|equivalent| x g end definition example \"|zero| : x = 0 expect g x = \"0\" end example end law\nend unit\n"] `shouldSatisfy` isRight
    it "accepts the reverse round trip with quantified Text" $
      compile [source (concrete "apply law \"|left inverse| f g")] `shouldSatisfy` isRight
    it "rejects recursive expansion" $
      compile [source (concrete "`codec`")] `shouldSatisfy` isLeft
    it "rejects unknown functions" $
      compile [source (concrete "apply law \"|left inverse| missing f")] `shouldSatisfy` isLeft
    it "rejects missing Eq constraints on generic laws" $
      compile [Source "generic.lawspec" "unit generic\n\nlaw \"|id| (f :: a -> a) is definition : for all (x :: a) => f x = x end for all end definition end law\nend unit\n"] `shouldSatisfy` isLeft
    it "does not specialize rigid generic parameters to hide a mismatch" $
      compile [Source "generic.lawspec" "unit generic\n\nlaw \"|bad| (f :: a -> b) requires Eq a is definition : for all (x :: a) => f x = x end for all end definition end law\nend unit\n"] `shouldSatisfy` isLeft
    it "rejects an incorrect inherited example input" $
      compile [source "law \"|codec| is definition : apply law \"|left inverse| g f end definition example \"|bad| : y = 1 expect g (f x) = 1 end example end law\n"] `shouldSatisfy` isLeft
    it "rejects out-of-range examples" $
      compile [source "law \"|codec| is definition : apply law \"|left inverse| g f end definition example \"|bad| : x = 2147483648 expect g (f x) = 0 end example end law\n"] `shouldSatisfy` isLeft
    it "accepts multiple independent quantified inputs" $
      compile [source (concrete "for all (x :: Int32) (y :: Int32) => g (f x) = y end for all")] `shouldSatisfy` isRight
    it "does not capture an argument named like an inherited input" $
      compile [Source "capture.lawspec" "unit capture\n\nx :: Int32 -> Text\ng :: Text -> Int32\nlaw \"|ok| is definition : apply law \"|left inverse| g x end definition end law\nend unit\n"] `shouldSatisfy` isRight
    it "checks Text and mixed example fixtures" $ do
      mapM_ (\name -> do
        text <- readFile ("examples/specs/" ++ name ++ ".lawspec")
        compile [Source (name ++ ".lawspec") text] `shouldSatisfy` isRight) ["slug", "canonical_url", "mixed_inputs"]
    it "rejects example values that do not match input types" $ do
      compile [Source "bad.lawspec" "unit bad\n\nf :: Text -> Text\nlaw \"|bad| is definition : apply law \"|idempotent| f end definition example \"|bad| : x = 42 expect f x = 42 end example end law\nend unit\n"] `shouldSatisfy` isLeft
      compile [Source "bad.lawspec" "unit bad\n\nf :: Int32 -> Int32\nlaw \"|bad| is definition : apply law \"|idempotent| f end definition example \"|bad| : x = \"42\" expect f x = 42 end example end law\nend unit\n"] `shouldSatisfy` isLeft
    it "rejects non-scalar Text values" $
      compile [Source "bad.lawspec" ("unit bad\nf :: Text -> Text\nlaw \"|bad| is definition: apply law \"|idempotent| f end definition example bad: x = \"" ++ ['\xD800'] ++ "\" expect f x = \"\" end example end law\nend unit\n")] `shouldSatisfy` isLeft
    it "requires the same input and output types for idempotence" $
      compile [Source "bad.lawspec" "unit bad\n\nf :: Text -> Int32\nlaw \"|bad| is definition : apply law \"|idempotent| f end definition end law\nend unit\n"] `shouldSatisfy` isLeft
    it "requires an expected result in every example" $
      compile [Source "missing.lawspec" "unit missing\n\nf :: Int32 -> Int32\nlaw \"|identity| is definition : apply law \"|idempotent| f end definition example \"|zero| : x = 0 end example end law\nend unit\n"] `shouldSatisfy` (\r -> case r of Left ds -> any (isInfixOf "requires at least one expect" . message) ds; _ -> False)
    it "type-checks expectation results" $
      compile [Source "wrong.lawspec" "unit wrong\n\nf :: Int32 -> Text\nlaw \"|same| is definition : apply law \"|equivalent| f f end definition example \"|zero| : x = 0 expect f x = 0 end example end law\nend unit\n"] `shouldSatisfy` isLeft
    it "supports composed expectation expressions" $
      compile [source "law \"|codec| is definition : apply law \"|left inverse| g f end definition example \"|negative| : x = -42 expect (g . f) x = -42 end example end law\n"] `shouldSatisfy` isRight
  describe "predicates" $ do
    it "compiles the port and Boolean examples" $ do
      mapM_ (\name -> do
        text <- readFile ("examples/specs/" ++ name ++ ".lawspec")
        compile [Source (name ++ ".lawspec") text] `shouldSatisfy` isRight) ["parse_port", "boolean_flags"]
    it "keeps guarded caller inputs distinct from a nested law's inputs" $ do
      case compile [Source "guards.lawspec" "unit guards\n\np :: Int32 -> Bool\nf :: Int32 -> Int32\nlaw \"|check| is definition : for all (x :: Int32) => p x implies apply law \"|idempotent| f end for all end definition end law\nend unit\n"] of
        Right (_, [e]) -> do
          length (inputs e) `shouldBe` 1
          let outer = inputId (head (inputs e))
          case assertion e of
            AssertImplies guard (AssertQuantified ForEvery inner (AssertEqual a b)) -> do
              stripLocations guard `shouldBe` Apply (Var "p") (Var outer)
              inputId inner `shouldNotBe` outer
              stripLocations a `shouldBe` Apply (Var "f") (Apply (Var "f") (Var (inputId inner)))
              stripLocations b `shouldBe` Apply (Var "f") (Var (inputId inner))
            other -> expectationFailure (show other)
        other -> expectationFailure (show other)
    it "preserves caller predicate arguments named like inherited inputs" $ do
      let text = "unit guards\n\nx :: Int32 -> Bool\nf :: Int32 -> Text\ng :: Text -> Int32\nlaw \"|check| is definition : apply law \"|left inverse when| x g f end definition end law\nend unit\n"
      case compile [Source "guards.lawspec" text] of
        Right (_, [e]) -> do
          prettyExpanded e `shouldBe` "for all (x :: Int32) => x (x) implies g (f (x)) = x end for all"
          map stripLocations (guards e) `shouldBe` [Apply (Var "x") (Var (inputId (head (inputs e))))]
        other -> expectationFailure (show other)
    it "accepts nested implications and Boolean predicate conclusions" $
      compile [Source "bool.lawspec" "unit bools\n\nf :: Bool -> Bool\nlaw \"|nested| is definition : for all (x :: Bool) => x implies f x implies true end for all end definition example \"|enabled| : x = true expect f x = true end example end law\nend unit\n"] `shouldSatisfy` isRight
    it "requires Boolean conditions and predicate conclusions" $ do
      mapM_ (\d -> compile [source (concrete ("for all (x :: Int32) => " ++ d ++ " end for all"))] `shouldSatisfy` isLeft)
        ["x implies x = x", "f x implies x = x", "x", "f x"]
    it "rejects unknown guard values and Boolean/int expectation mismatches" $ do
      compile [source (concrete "for all (x :: Int32) => missing x implies x = x end for all")] `shouldSatisfy` isLeft
      compile [Source "bad.lawspec" "unit bad\n\nf :: Int32 -> Bool\nlaw \"|check| is definition : apply law \"|satisfies| f end definition example \"|zero| : x = 0 expect f x = 1 end example end law\nend unit\n"] `shouldSatisfy` isLeft
    it "checks generic predicate constraints without requiring Eq of the input" $
      compile [Source "generic.lawspec" "unit generic\n\nlaw \"|predicate| (p :: a -> Bool) is definition : apply law \"|satisfies| p end definition end law\nend unit\n"] `shouldSatisfy` isRight
  describe "algebra and currying" $ do
    it "compiles every algebra and partial-application example" $ do
      mapM_ (\n -> do
        text <- readFile ("examples/specs/" ++ n ++ ".lawspec")
        compile [Source (n ++ ".lawspec") text] `shouldSatisfy` isRight) ["algebra", "currying"]
    it "accepts exactly the generic commutative and associative signatures" $ do
      let generic name body = Source "generic.lawspec" ("unit generic\nlaw \"|" ++ name ++ "| (f :: a -> a -> a) requires Eq a is definition: " ++ body ++ " end definition end law\nend unit\n")
      compile [generic "commutes" "for all (x :: a) (y :: a) => f x y = f y x end for all"] `shouldSatisfy` isRight
      compile [generic "associates" "for all (x :: a) (y :: a) (z :: a) => f (f x y) z = f x (f y z) end for all"] `shouldSatisfy` isRight
    it "checks scalar identity parameters and rejects wrong types or arities" $ do
      let spec d = Source "arity.lawspec" ("unit arity\nf :: Int32 -> Int32 -> Int32\nlaw \"|check| is definition: " ++ d ++ " end definition end law\nend unit\n")
      compile [spec "apply law \"|left identity| f 0"] `shouldSatisfy` isRight
      mapM_ (\d -> compile [spec d] `shouldSatisfy` isLeft)
        ["apply law \"|left identity| f true", "apply law \"|commutative| (f 1)", "for all (x :: Int32) => f x = x end for all", "for all (x :: Int32) => f x x x = x end for all"]
    it "retains every conjunct and shared conditional scope" $ do
      let spec = Source "both.lawspec" "unit both\n\nlaw \"|check| is definition : for all (x :: Bool) => x implies x = true and true = x end for all end definition end law\nend unit\n"
      case compile [spec] of
        Right (_, [e]) -> case assertion e of
          AssertImplies _ (AssertAll [AssertEqual _ _, AssertEqual _ _]) -> pure ()
          other -> expectationFailure (show other)
        other -> expectationFailure (show other)
    it "requires Eq constraints for all generic equality conclusions" $
      compile [Source "bad.lawspec" "unit bad\n\nlaw \"|check| (f :: a -> a -> a) is definition : apply law \"|commutative| f end definition end law\nend unit\n"] `shouldSatisfy` isLeft
  describe "emission" $ do
    it "emits tests and user-owned adapters for all eight targets" $ do
      s <- readFile "examples/specs/atoi_codec.lawspec"
      case compile [Source "codec.lawspec" s] of
        Left ds -> expectationFailure (show ds)
        Right (us,es) -> mapM_ (\t -> case emit t us es of
          Left ds -> expectationFailure (show ds)
          Right fs -> do
            filter ((== "user") . ownership) fs `shouldSatisfy` (not . null)
            concatMap artifactContent fs `shouldSatisfy` isInfixOf "2147483647") targets

    it "keeps abstract Integer adapter results polymorphic over the integral tower" $ do
      let input = Source "tower.lawspec" "unit example.tower\n\nadd :: Integer -> Integer -> Integer\nlaw \"|add commutes| is definition : for all (x :: Integer) (y :: Integer) => add x y = add y x end for all end definition end law\nend unit\n"
          user fs = concatMap artifactContent (filter ((== "user") . ownership) fs)
          everything = concatMap artifactContent
      case compile [input] of
        Left ds -> expectationFailure (show ds)
        Right (us,es) -> mapM_ (\(t,signature,bridge) -> case emit t us es of
          Left ds -> expectationFailure (show ds)
          Right fs -> do
            user fs `shouldSatisfy` isInfixOf signature
            everything fs `shouldSatisfy` isInfixOf bridge)
          [ ("java","public static Number add(","LawSpecRuntime.fromNative(")
          , ("kotlin","java.math.BigInteger): Number","LawSpecRuntime.fromNative(")
          , ("haskell","-> LS.IntegerValue","LS.fromNative") ]

    it "retains executable laws even without implementation functions" $ do
      let input = Source "pure.lawspec" "unit purelaw\n\nlaw \"|reflexive| is definition : for all (x :: Int32) => x = x end for all end definition end law\nend unit\n"
      case compile [input] of
        Left ds -> expectationFailure (show ds)
        Right (us,es) -> case emit "python" us es of
          Left ds -> expectationFailure (show ds)
          Right fs -> do
            let tests = filter ((== "test") . artifactPlacement) fs
            length tests `shouldBe` 1
            concatMap artifactContent tests `shouldSatisfy` isInfixOf "test_reflexive__property"
            concatMap artifactContent tests `shouldSatisfy` (not . isInfixOf "from purelaw import")
    it "moves generated imports with a custom layout" $ do
      s <- readFile "examples/specs/atoi_codec.lawspec"
      case compile [Source "codec.lawspec" s] of
        Left ds -> expectationFailure (show ds)
        Right (us,es) -> case emitWithLayout "javascript" (Just "lib") (Just "checks/unit") us es of
          Left ds -> expectationFailure (show ds)
          Right fs -> do
            artifactPath (head fs) `shouldBe` "lib/example/atoi_codec.mjs"
            concatMap artifactContent (filter ((== "test") . artifactPlacement) fs) `shouldSatisfy` isInfixOf "../../lib/example/atoi_codec.mjs"

  describe "portable scalars" $ do
    it "recognizes every scalar domain and both presence constructors" $ do
      let canonical "BigInt" = "Integer"
          canonical "BigUInt" = "Whole"
          canonical name = name
          types = map (canonical . primitiveName) primitives ++ ["Optional (Nullable Int8)","Nullable (Optional Bool)"]
      mapM_ (\t -> compile [Source "all" ("unit domain\nf :: " ++ t ++ " -> " ++ t ++ "\nlaw \"|identity| is definition : apply law \"|equivalent| f f end definition end law\nend unit\n")] `shouldSatisfy` isRight) types
    it "compiles the executable scalar and adapter examples" $ do
      mapM_ (\n -> readFile ("examples/specs/" ++ n ++ ".lawspec") >>= \s -> compile [Source n s] `shouldSatisfy` isRight) ["scalars","scalar_adapters"]
    it "promotes primitive integer arithmetic to Integer and division to Rational" $ do
      let env = [("x",Named "Int8")]
      fmap expressionType (typedExpression 64 env (Binary "+" (Var "x") (Number 1))) `shouldBe` Right (Named "Integer")
      fmap expressionType (typedExpression 64 env (Binary "/" (Var "x") (Number 2))) `shouldBe` Right (Named "Rational")
    it "checks contextual literals at both machine widths" $ do
      let s = Source "width" "unit width\n\nf :: IntSize -> IntSize\nlaw \"|id| is definition : apply law \"|equivalent| f f end definition example \"|large| : x = 2147483648 expect f x = 2147483648 end example end law\nend unit\n"
      compileWithProfile 32 [s] `shouldSatisfy` isLeft
      compileWithProfile 64 [s] `shouldSatisfy` isRight
      compileWithProfile 16 [] `shouldSatisfy` isLeft
    it "rejects implicit exact/inexact mixing and Bool arithmetic" $ do
      let env = [("x",Named "Float32"),("y",Named "Int8"),("b",Named "Bool")]
      typedExpression 64 env (Binary "+" (Var "x") (Var "y")) `shouldSatisfy` isLeft
      typedExpression 64 env (Binary "+" (Var "b") (Number 1)) `shouldSatisfy` isLeft
      typedExpression 64 env (Binary "+" (Var "x") (Apply (Var "prelude.Float32") (Var "y"))) `shouldSatisfy` isRight
    it "checks operator precedence while preserving signed application" $ do
      let spec text = parseSource (Source "precedence" ("unit p\nlaw \"|p| is definition: for all (x :: Int8) => " ++ text ++ " = x end for all end definition end law\nend unit\n"))
      case spec "x + 2 * 3" of
        Right u -> case definition (head (laws u)) of
          Forall [("x",Named "Int8")] (Equal a b) -> (stripLocations a,stripLocations b) `shouldBe` (Binary "+" (Var "x") (Binary "*" (Number 2) (Number 3)),Var "x")
          other -> expectationFailure (show other)
        Left ds -> expectationFailure (show ds)
      case spec "f -42" of
        Right u -> case definition (head (laws u)) of
          Forall [("x",Named "Int8")] (Equal a b) -> (stripLocations a,stripLocations b) `shouldBe` (Apply (Var "f") (Number (-42)),Var "x")
          other -> expectationFailure (show other)
        Left ds -> expectationFailure (show ds)
    it "validates raw domains without surrogate replacement" $ do
      validateScalar 64 (SSequence "Text" [55296]) `shouldSatisfy` isLeft
      validateScalar 64 (SSequence "CodePointText" [55296]) `shouldSatisfy` isRight
      validateScalar 64 (SSequence "Utf16Text" [55296,65535]) `shouldSatisfy` isRight
      validateScalar 64 (SSequence "Bytes" [256]) `shouldSatisfy` isLeft
      validateScalar 64 (SCharacter "Char" 128512) `shouldSatisfy` isRight
      validateScalar 64 (SCharacter "CodeUnit16" 128512) `shouldSatisfy` isLeft
    it "checks exact conversion and rational canonicalization" $ do
      convertScalar 64 "Int8" (SRational 1 2) `shouldSatisfy` isLeft
      convertScalar 64 "Int8" (SInteger "BigInt" 128) `shouldSatisfy` isLeft
      convertScalar 64 "Decimal" (SRational 1 3) `shouldSatisfy` isLeft
      validateScalar 64 (SRational 4 (-6)) `shouldBe` Right (SRational (-2) 3)
      validateScalar 64 (SRational 1 0) `shouldSatisfy` isLeft
    it "places generated runtimes in source directories with custom layouts" $ do
      s <- readFile "examples/specs/scalars.lawspec"
      case compile [Source "scalars" s] of
        Left ds -> expectationFailure (show ds)
        Right (us,es) -> case emitWithLayout "javascript" (Just "lib") (Just "checks/unit") us es of
          Left ds -> expectationFailure (show ds)
          Right fs -> do
            [artifactPath a | a <- fs, artifactPlacement a == "source", ownership a == "generated"] `shouldBe` ["lib/lawspec_data.mjs", "lib/lawspec_schema.mjs", "lib/lawspec_runtime.mjs"]
            artifactContent (fs !! 1) `shouldSatisfy` isInfixOf "../../lib/lawspec_runtime.mjs"

    it "infers tagged presence literals in law assertions" $ do
      compile [Source "absence" "unit absence\n\nlaw \"|missing| is definition : for all (x :: Optional Int8) => x = undefined end for all end definition end law\nend unit\n"] `shouldSatisfy` isRight
      compile [Source "presence" "unit presence\n\nlaw \"|present| is definition : for all (x :: Optional Int8) => x = optional(7) end for all end definition end law\nend unit\n"] `shouldSatisfy` isRight
    it "keeps explicit Decimal constructors distinct from contextual decimal tokens" $ do
      let env = [("x",Named "Float32")]
      typedExpression 64 env (Binary "+" (Var "x") (DecimalNumber 1 (-1))) `shouldSatisfy` isRight
      typedExpression 64 env (Binary "+" (Var "x") (ScalarLit (SDecimal 1 (-1)))) `shouldSatisfy` isLeft
    it "retains promoted operation types and checked bridge targets in the IR" $ do
      let env = [("f",Arrow (Named "Int8") (Named "Int8")),("x",Named "Int8")]
      case typedExpression 64 env (Apply (Var "f") (Binary "+" (Var "x") (Number 0))) of
        Right ir -> do
          expressionType (operands ir !! 1) `shouldBe` Named "Integer"
          requiredConversion (operands ir !! 1) `shouldBe` Just (Named "Int8")
        Left e -> expectationFailure e

    it "specializes generic laws over nested presence types" $ do
      let s = Source "generic-presence" "unit generic_presence\n\nf :: Optional (Nullable Int8) -> Optional (Nullable Int8)\nlaw \"|identity| (g :: Optional a -> Optional a) requires Eq (Optional a) is definition : for all (x :: Optional a) => g x = x end for all end definition end law\nlaw \"|concrete| is definition : apply law \"|identity| f end definition end law\nend unit\n"
      compile [s] `shouldSatisfy` isRight


  describe "dependent refinements" $ do
    let spec body = Source "refinement.lawspec" ("unit refinement\n\n" ++ body ++ "\nend unit\n")
        law qs body = "law \"|check| is definition: for all " ++ qs ++ " => " ++ body ++ " end for all end definition end law"
    it "compiles parameterized refinements and independently executable contracts" $ do
      text <- readFile "examples/specs/refinements.lawspec"
      case compile [Source "refinements" text] of
        Left ds -> expectationFailure (show ds)
        Right (us,es) -> do
          length (contracts (head us)) `shouldBe` 6
          length (filter ((== "contract") . propertyKind) es) `shouldBe` 6
          length (refinements (head us)) `shouldBe` 3
    it "finds exactly the mathematical Int8 overflow pairs" $ do
      let s = spec (law "(x :: Int8) (y :: Int8 where y > Int8.max - x)" "x + y > Int8.max")
      case compile [s] of
        Left ds -> expectationFailure (show ds)
        Right (_, [e]) -> do
          let expected = [[SInteger "Int8" x,SInteger "Int8" y] | x <- [-128..127], y <- [-128..127], x+y>127]
          D.finiteTuples 64 defaultGeneration{exhaustiveLimit=65536} (inputs e) `shouldBe` Right (Just expected)
          length expected `shouldBe` 8128
          all (\xs -> case xs of [SInteger _ x,SInteger _ y] -> x>0 && x+y>=128 && x+y<=254; _ -> False) expected `shouldBe` True
    it "rejects examples outside the dependent domain" $
      compile [spec ("law \"|bad| is definition : for all (x :: Int8) (y :: Int8 where y > Int8.max - x) => x + y > Int8.max end for all end definition example \"|invalid| : x = 0 y = 127 expect x + y = 127 end example end law\n")] `shouldSatisfy` isLeft
    it "separates valid empty domains from executable generation and rejects non-Boolean refinements" $ do
      case compile [spec (law "(x :: Bool where false)" "x = x")] of
        Left ds -> expectationFailure (show ds)
        Right (us,es) -> mapM_ (\target -> emit target us es `shouldSatisfy` isRight) targets
      compile [spec (law "(x :: Int8 where x)" "x = x")] `shouldSatisfy` isLeft
    it "permits a prefix with no continuation without treating the whole domain as empty" $
      compile [spec (law "(x :: Int8) (y :: Int8 where y > Int8.max - x)" "x + y > Int8.max")] `shouldSatisfy` isRight
    it "rejects adapter calls in predicates" $
      compile [spec ("valid :: Int8 -> Bool\n" ++ law "(x :: Int8 where valid x)" "x = x")] `shouldSatisfy` isLeft
    it "rejects forward value references and recursive aliases" $ do
      compile [spec (law "(x :: Int8 where x > y) (y :: Int8)" "x = x")] `shouldSatisfy` isLeft
      compile [spec "refinement Loop is (x :: Loop where true) end refinement\n"] `shouldSatisfy` isLeft
    it "resolves forward refinement declarations and zero-parameter aliases" $
      compile [spec ("identity :: Positive -> Positive\nrefinement Positive is (x :: Int8 where x > 0) end refinement\n")] `shouldSatisfy` isRight
    it "checks capabilities on unused generic refinements" $ do
      compile [spec "refinement Positive (T :: Type) is (x :: T where x > 0) end refinement\n"] `shouldSatisfy` isLeft
      compile [spec "refinement Positive (T :: Type) requires Ordered T is (x :: T where x > 0) end refinement\n"] `shouldSatisfy` isRight
    it "rejects invalid scalar specializations" $ do
      compile [spec ("refinement Positive (T :: Type) requires Integer T is (x :: T where x > 0) end refinement\n" ++ law "(x :: Positive Float64)" "x = x")] `shouldSatisfy` isLeft
      compile [spec (law "(x :: Integer)" "x < Integer.max")] `shouldSatisfy` isLeft
    it "supports abstract results and integer-constrained reusable laws" $
      compile [spec ("f :: Int8 -> Integer\nlaw \"|successor| (g :: a -> b) requires Integer a Integer b is definition : for all (x :: a) => g x = x + 1 end for all end definition end law\nlaw \"|instance| is definition : apply law \"|successor| f end definition end law\n")] `shouldSatisfy` isRight
    it "checks dependent postcondition scope" $ do
      compile [spec "f :: (x :: Int8) -> (r :: Integer where r == x + 1)"] `shouldSatisfy` isRight
      compile [spec "f :: (x :: Int8) -> (r :: Integer where r == missing)"] `shouldSatisfy` isLeft
    it "composes nested presence refinements" $
      compile [spec ("refinement Positive is (x :: Int8 where x > 0) end refinement\n" ++ law "(x :: Optional (Nullable Positive))" "x = x")] `shouldSatisfy` isRight
    it "preserves short circuiting in pure reference evaluation" $ do
      evaluateBool 64 [] (Binary "&&" (BoolLit False) (Binary ">" (Binary "/" (Number 1) (Number 0)) (Number 0))) `shouldBe` Right False
      evaluateBool 64 [] (Binary "||" (BoolLit True) (Binary ">" (Binary "/" (Number 1) (Number 0)) (Number 0))) `shouldBe` Right True
      evaluateBool 64 [] (Binary ">" (Binary "/" (Number 1) (Number 0)) (Number 0)) `shouldSatisfy` isLeft
    it "resolves machine bounds from the requested profile" $ do
      boundsValue 32 "max" (Named "IntSize") `shouldBe` Right (SInteger "Integer" 2147483647)
      boundsValue 64 "max" (Named "IntSize") `shouldBe` Right (SInteger "Integer" 9223372036854775807)
    it "rejects invalid generation limits" $
      compileWithSettings 64 defaultGeneration{maxAttempts=0} [spec (law "(x :: Int8)" "x = x")] `shouldSatisfy` isLeft

    it "avoids capturing a value argument with an alias's own binder" $ do
      let header = "refinement GreaterThan (T :: Type) (lower :: T) requires Ordered T is (x :: T where x > lower) end refinement\n"
          body = "law dependent is definition: for all (x :: Int8) (y :: GreaterThan Int8 x) => y > x end for all end definition example valid: x = 0 y = 1 expect y = 1 end example end law"
      compile [spec (header ++ body)] `shouldSatisfy` isRight
    it "rejects capability mismatches in refined results" $
      compile [spec "refinement Positive (T :: Type) requires Integer T is (x :: T where x > 0) end refinement\nf :: Int8 -> Positive Float64\n"] `shouldSatisfy` isLeft

    it "enforces refinements on named refinement value parameters" $ do
      let header = "refinement Positive is (x :: Int8 where x > 0) end refinement\nrefinement Above (lower :: Positive) is (value :: Int8 where value > lower) end refinement\n"
      compile [spec (header ++ law "(x :: Above (-1))" "x = x")] `shouldSatisfy` isLeft
      compile [spec (header ++ law "(x :: Above 1)" "x = x")] `shouldSatisfy` isRight

    it "evaluates complex equality and negation in pure predicates" $ do
      let z = SComplex "Complex64" (floatScalar "Float32" 1) (floatScalar "Float32" 2)
          negative = SComplex "Complex64" (floatScalar "Float32" (-1)) (floatScalar "Float32" (-2))
      evaluateBool 64 [] (Binary "==" (ScalarLit z) (ScalarLit z)) `shouldBe` Right True
      evaluateBool 64 [] (Binary "!=" (ScalarLit z) (ScalarLit negative)) `shouldBe` Right True
      evaluate 64 [] (Unary "-" (ScalarLit z)) `shouldBe` Right negative
