-- | The compiler's one entry point for every host: the native lawspec-core
-- executable, the WASM core the npm package and the documentation site load,
-- and lawspec-dev docs all speak the same JSON request and response, so the
-- targets and the two builds cannot drift apart. ref:DEC-wasm-distribution
module LawSpec.Api (dispatch) where
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import Control.Monad (unless)
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString.Lazy as B
import LawSpec.Model
import LawSpec.Digest (digestString, digestHex)
import LawSpec.SourceText (formatSourceWithSyntax, formatSourcesUsing)
import LawSpec.SourceSyntax (SourceSyntax(..))
import LawSpec.Compile
import LawSpec.Frontend (elaborateCanonical,sourcePropertyId)
import LawSpec.Testing (Plan(..), PlannedUnit(..), PlannedProperty(..), planTesting, planTestingWith)
import qualified LawSpec.Core.Verification as V
import qualified LawSpec.Core.Smt as Smt
import qualified LawSpec.Core as C
import LawSpec.Core.Evidence (Obligation(..), Status(..), statusName)
import LawSpec.CoreEmit (emitPlanWithNativeOptions)
import LawSpec.Targets (artifactTargets)
import LawSpec.NativeRequest
import LawSpec.Public (programView, obligationView)
import LawSpec.Packages
import LawSpec.Discharge (dischargeReporting, refutations, bindingEvidence, defaultHandlerEvidence, showValue)
import qualified LawSpec.Core.Counterexample as Counterexample
import qualified LawSpec.Core.LawAnalysis as Analysis
import LawSpec.ProofSettings (proofSettings)
import LawSpec.ModelLaws (modelLawEvidence, historyLawEvidence, ModelRun(..))
import qualified LawSpec.ModelProof as ModelProof
import LawSpec.LawClaims (elaborateClaims, Expiry(..), analysisEvidence, analysisTaskViews, settleAnalysis)
import qualified LawSpec.Core.LawTasks as Tasks
import LawSpec.Attestation (Attestation, parseAttestation, attestedFields, attestationView)
import LawSpec.Explain (ExplainOptions(..), View(..), parseView, explainResult)
import Data.Foldable (toList)
import Data.Maybe (fromMaybe)
import qualified Data.Map.Strict as M
import LawSpec.TestManifest (TestEntry(..), testManifest, testManifestWithModelChecks, executableEntries, BenchmarkEntry(..), benchmarkManifest)
import LawSpec.Memo (Table, newTable, memoized, withCacheDirectory)
import qualified Data.ByteString.Lazy.Char8 as BC
import qualified Data.Aeson.Key as K
import qualified Data.Text as T
import System.IO.Unsafe (unsafePerformIO)

-- | One function from request bytes to response bytes, because that is all a
-- WASM export can carry without a shared heap; the work every method shares is
-- memoised so a host asking for several targets compiles once.
-- ref:DEC-incremental-compilation
dispatch :: B.ByteString -> B.ByteString
dispatch bytes = withCacheDirectory cacheDirectory $ encode $ versioned $ case eitherDecode bytes >>= parseEither request of
  Left err -> failure [Diagnostic "request" err Nothing]
  Right (_, _, Left err) -> failure [Diagnostic "attestation" err Nothing]
  Right ((method,sources,_,_,_,_,_,_,_,_),(project,packages),Right _)
    | method == "format", not formatCompilation ->
      either failure (\formatted -> object
        ["diagnostics" .= ([] :: [Diagnostic]), "formattedSources" .= formatted,
         "languageProfile" .= ("1.0-rc.2" :: String)])
          (formatSourcesUsing (formatSyntax project packages) sources)
  -- An unknown or removed explanation view fails before compilation.
  Right ((method,_,_,_,_,_,_,_,_,_),_,_) | method == "explain", Left err <- explainOptions ->
    failure [Diagnostic "explain" err Nothing]
  Right ((method,sources,target,sourceDir,testDir,bits,settings,minify,native,verification),(project,packages),Right attestation) ->
   -- Typed compilation is shared across targets. SMT task preparation has a
   -- separate key because it prepares, rather than executes, optional proofs.
   let taskMethod = method == "proofTasks"
       -- Task preparation does not run the older optional law prover. Intrinsic
       -- definition admission remains in compilation, independently of this.
       stageVerification = if taskMethod then fmap (\config -> V.Verification
         (filter (/= V.Proof) (V.verificationLayers config))) verification else verification
       stageKey = (if taskMethod then "smt-task-preparation:" else "") ++ sharedRequest bytes
   in case (if method=="format" || matchWarningsRequested then memoized syntaxStagesTable ("canonical:" ++ stageKey)
          (stagesWithInput True True project packages sources bits settings native stageVerification)
        else fmap (\value -> (value,[])) (memoized stagesTable stageKey (stages project packages sources bits settings native stageVerification))) of
    Left response -> response
    Right ((us,es,core,bindings,(lawEvidence,analysisRows),described,plan),syntax) ->
     either failure id $ fmap (\analysed -> let evidence = lawEvidence ++ map fst analysed in withExemptions analysed $
     let pending item | method=="proofTasks", maybe False (`V.selected` V.Proof) verification,
                        obligationStage item=="law", obligationStatus item==NotVerified =
                          case [why | unit<-C.programUnits core, law<-C.unitProperties unit,
                            C.propertyId law==obligationDeclaration item,
                            Just why<-[C.harnessKnownFailing (C.propertyHarness law)]] of
                            why:_ -> item{obligationStatus=KnownFailing,obligationReason="marked known failing: "++why}
                            [] -> item{obligationStatus=Planned,obligationReason="an SMT proof task is requested; no solver execution has completed"}
                      | otherwise = item
         obligations = map pending evidence ++ bindingEvidence bindings ++ defaultHandlerEvidence core bindings
         -- A refuted law keeps its row and fails the request.
         result files = withRefutations (refutations core obligations) $ (if matchWarningsRequested then withMatchWarnings syntax else id) $
           withAttestation attestation core obligations (withVerification verification (withPackages project described (programView settings us (map prettyExpanded es) files obligations (C.lowerProgramFields core)))) in case method of
          "check" -> result []
          "expand" -> result []
          -- Presentation of the expanded laws; it changes no obligation.
          "explain" | Right options <- explainOptions -> case result [] of
            Object response -> either (\err -> failure [Diagnostic "explain" err Nothing])
              (\explained -> case explained of
                Object e -> Object (KM.insert "diagnostics" (fromMaybe (toJSON ([] :: [Diagnostic])) (KM.lookup "diagnostics" response)) e)
                other -> other)
              (explainResult options (Object response))
            response -> response
          "proofTasks" | Just selection <- verification ->
            if V.selected selection V.Proof
              then either failure (\tasks -> case result [] of
                Object response -> withModelTasks us core evidence modelAnswers (withAnalysisTasks us core analysisRows
                  (Object (withCounterexampleChecks core tasks (KM.insert "proofTasks" (toJSON tasks) response))))
                response -> response) (proofSettings us >>= \settings -> Smt.proofTasksWith settings core)
              else case result [] of
                Object response -> Object (KM.insert "proofTasks" (toJSON ([] :: [Smt.ProofTask])) response)
                response -> response
          "proofTasks" -> failure [Diagnostic "language-profile" "proofTasks requires API schema 5 and languageProfile 1.0-rc.2" Nothing]
          "format" | verification /= Nothing ->
            let formattedSources=[formatSourceWithSyntax
                  (concat [syntaxNodes item | item<-syntax,syntaxPath item==path source]) source | source<-sources]
            in case preparePackagesWithOrigins True project packages formattedSources of
              Left ds -> failure ds
              Right (formatted,origins,visible,referenceUnit,_) -> case compileWithSourceOrigins origins False True referenceUnit visible bits settings formatted of
                Left ds -> failure ds
                Right _ -> withSources formattedSources (result [])
          "format" -> failure [Diagnostic "language-profile" "format requires API schema 5 and languageProfile 1.0-rc.2" Nothing]
          "planGeneration" | target `elem` artifactTargets, native /= emptyNativeRequest ->
            failure [Diagnostic "native-binding" "artifact targets do not support native bindings" Nothing]
          "planGeneration" -> either failure (withBenchmarks (benchmarkManifest target testDir core) . withTests core verification plan (verificationKeys verification
              (either (const id) executableEntries plan
                (testManifestWithModelChecks (maybe True (`V.selected` V.Model) verification) target testDir (plannedCore core plan)))) . result)
            ((++ networkArtifacts native) <$> (plan >>= emitPlanWithNativeOptions minify target sourceDir testDir bindings))
          _ -> failure [Diagnostic "request" ("unknown method: " ++ method) Nothing])
       (analysisEvidence (maybe True (\config -> V.selected config V.Exhaustive || V.selected config V.Proof) verification)
          (maybe True (`V.selected` V.Proof) verification) False expiry analysisRows)

  where
    formatSyntax project packages sources =
      case preparePackagesWithOrigins True project packages sources of
        Right (prepared,origins,_,_,_) ->
          let (dependencies,own) = splitAt (length prepared - length sources) prepared
          in parseSourceSyntaxWithContext origins dependencies own
        -- Unfinished package wiring must not turn formatting into a compiler
        -- check. Available raw headers can still disambiguate type arities.
        Left _ -> parseSourceSyntaxWithContext [] (concatMap packageSources packages) sources
    -- The explanation register, law selector and any host-completed evidence
    -- rows (native observations); none of them changes compilation.
    explainOptions = case decode bytes of
      Just (Object o) -> do
        view <- case KM.lookup "view" o of
          Nothing -> Right Eng
          Just Null -> Right Eng
          Just (String v) -> parseView v
          Just _ -> Left "explain view must be a string; choose --view eng|math|dev"
        law <- case KM.lookup "law" o of
          Nothing -> Right Nothing
          Just Null -> Right Nothing
          Just (String l) -> Right (Just l)
          Just _ -> Left "explain law must be a string <unit>::<law>"
        evidence <- case KM.lookup "evidence" o of
          Nothing -> Right Nothing
          Just Null -> Right Nothing
          Just rows@(Array _) -> Right (Just rows)
          Just _ -> Left "explain evidence must be an array of evidence rows"
        Right (ExplainOptions view law evidence)
      _ -> Left "explain requires a JSON object request"
    -- Checked formatting stays the SDK default. The CLI explicitly selects
    -- parsing alone unless its caller requests --compile.
    formatCompilation = case decode bytes of
      Just (Object o) | Just (Bool requested) <- KM.lookup "compile" o -> requested
      _ -> True
    -- Where the compiler may keep work between runs; the CLI names one per
    -- project and compiler build.
    cacheDirectory = case decode bytes of
      Just (Object o) | Just (String d) <- KM.lookup "cacheDirectory" o -> Just (T.unpack d)
      _ -> Nothing
    -- The host's counterexample values, each bound to a task it ran
    -- (LawSpec.Core.Counterexample). The compiler re-derives the query and
    -- re-checks the values; it trusts neither the host nor Z3.
    withCounterexampleChecks core tasks response = case decode bytes of
      Just (Object o) | Just (Array asked) <- KM.lookup "proofCounterexamples" o ->
        KM.insert "counterexampleChecks" (toJSON [counterexampleCheck core tasks item | item <- toList asked]) response
      _ -> response
    counterexampleCheck core tasks item = case item of
      Object o | Just (String owner) <- KM.lookup "owner" o, Just (String law) <- KM.lookup "declaration" o
               , Just (String fingerprint) <- KM.lookup "taskFingerprint" o, Just (String answer) <- KM.lookup "values" o ->
        let identity = ["owner" .= owner, "declaration" .= law, "taskFingerprint" .= fingerprint]
        in case [t | t <- tasks, C.idText (Smt.taskOwner t) == T.unpack owner, C.idText (Smt.taskLaw t) == T.unpack law,
                     Smt.taskFingerprint t == T.unpack fingerprint] of
          task : _ -> object (identity ++ counterexampleView (Counterexample.validateCounterexample core task (T.unpack answer)))
          [] -> object (identity ++ ["status" .= ("incomplete" :: String),
            "reason" .= ("the counterexample is bound to a task this program does not have" :: String)])
      _ -> object ["status" .= ("incomplete" :: String), "reason" .= ("malformed counterexample request" :: String)]
    counterexampleView check = ["status" .= Counterexample.checkStatus check] ++ case check of
      Counterexample.Refuted inputs why -> ["reason" .= why, "inputs" .= shown inputs]
      Counterexample.ModelNotConfirmed inputs why -> ["reason" .= why, "inputs" .= shown inputs]
      Counterexample.CheckIncomplete why -> ["reason" .= why]
    shown inputs = [object ["name" .= C.binderName (C.quantifiedBinder q), "value" .= showValue v] | (q, v) <- inputs]
    -- The host's answers to model tasks, by fingerprint.
    modelAnswers = case decode bytes of
      Just (Object o) | Just (Array given) <- KM.lookup "modelResults" o ->
        [ (T.unpack fp, ModelProof.Answer (T.unpack outcome) (text "values" a) (text "invariant" a))
        | Object a <- toList given, Just (String fp) <- [KM.lookup "fingerprint" a], Just (String outcome) <- [KM.lookup "outcome" a] ]
      _ -> []
      where text k a = case KM.lookup k a of Just (String v) -> T.unpack v; _ -> ""
    matchWarningsRequested = case decode bytes of
      Just (Object o) -> KM.lookup "warnMatches" o==Just (Bool True)
      _ -> False
    -- The law-set checks the compiler left undecided are Z3 tasks; their
    -- answers, sent back as analysisResults, settle them
    -- (LawSpec.LawClaims.settleAnalysis).
    withAnalysisTasks us core rows (Object response) =
      let claimsOf = elaborateClaims (C.programMachineBits core) us core
          withTasks = KM.insert "analysisTasks" (toJSON (either (const []) (\claims -> analysisTaskViews core claims rows) claimsOf)) response
          answers = case decode bytes of
            Just (Object o) | Just (Array given) <- KM.lookup "analysisResults" o ->
              Just [ (T.unpack fp, Tasks.Answer (T.unpack outcome) (maybe "" T.unpack values))
                   | Object a <- toList given, Just (String fp) <- [KM.lookup "fingerprint" a]
                   , Just (String outcome) <- [KM.lookup "outcome" a]
                   , let values = case KM.lookup "values" a of Just (String v) -> Just v; _ -> Nothing ]
            _ -> Nothing
      in case answers of
        Nothing -> Object withTasks
        Just given -> case claimsOf >>= \claims -> settleAnalysis True expiry claims core rows given of
          Left ds -> failure ds
          Right (evidence, verdicts) ->
            let refuted = refutations core (map fst evidence)
                existing = case KM.lookup "diagnostics" withTasks of Just (Array ds) -> toList ds; _ -> []
            in Object (KM.insert "analysisEvidence" (toJSON [ case (obligationView [] o, view) of
                                                                 (Object row, Just v) -> Object (KM.insert "exemption" v row)
                                                                 (row, _) -> row
                                                               | (o, view) <- evidence ])
                 (KM.insert "analysisChecks" (toJSON verdicts)
                 (KM.insert "diagnostics" (toJSON (existing ++ map toJSON refuted)) withTasks)))
    withAnalysisTasks _ _ _ response = response
    -- An exempted or expired check shows its exemption.
    withExemptions analysed (Object value) = case KM.lookup "evidence" value of
      Just (Array rows) -> Object (KM.insert "evidence" (Array (fmap (attach analysed) rows)) value)
      _ -> Object value
    withExemptions _ value = value
    attach analysed row = case row of
      Object o | Just view <- lookup (KM.lookup "declaration" o, KM.lookup "stage" o)
                   [ ((Just (toJSON (C.idText (obligationDeclaration item))), Just (toJSON (obligationStage item))), v)
                   | (item, Just v) <- analysed ] -> Object (KM.insert "exemption" view o)
      _ -> row
    expiry = case decode bytes of
      Just (Object o) -> Expiry
        (case (KM.lookup "projectVersion" o, KM.lookup "package" o) of
          (Just (String v), _) -> Just (T.unpack v)
          (_, Just (Object p)) | Just (String v) <- KM.lookup "version" p -> Just (T.unpack v)
          _ -> Nothing)
        (case KM.lookup "now" o of Just (String t) -> Just (T.unpack t); _ -> Nothing)
      _ -> Expiry Nothing Nothing
    withRefutations [] value = value
    withRefutations ds (Object value) = Object (KM.insert "diagnostics" (toJSON ds) value)
    withRefutations _ value = value
    withPackages project described (Object value) =
      Object (foldr (\(k, v) -> KM.insert k v) value (packagesView project described))
    withPackages _ _ value = value
    versioned (Object value) = Object (KM.insert "schemaVersion" (toJSON (5::Int)) value)
    versioned value = value
    request = withObject "request" $ \o -> do
      version <- o .:? "schemaVersion" .!= (5 :: Int)
      unless (version==5) (fail "LawSpec requires API schemaVersion 5 and languageProfile 1.0-rc.2")
      _ <- o .:? "warnMatches" .!= False
      _ <- o .:? "compile" .!= True
      method <- o .:? "method" .!= "check"
      native <- o .:? "nativeBindings" .!= emptyNativeRequest
      profile <- o .: "languageProfile"
      unless (profile == ("1.0-rc.2" :: String)) (fail "schema 5 requires languageProfile 1.0-rc.2")
      verification <- Just <$> o .:? "verification" .!= V.noVerification
      -- A project may itself be a package, and may depend on packages whose
      -- sources are supplied alongside its own.
      rootPackage <- o .:? "package" >>= traverse (withObject "package" (\p -> (,) <$> p .: "name" <*> p .: "version"))
      dependencies <- o .:? "dependencies" .!= mempty
      packages <- o .:? "packages" .!= []
      request' <- (,,,,,,,,,) <$> pure method <*> o .: "sources" <*> o .:? "target" .!= "" <*> o .:? "sourceDir" <*> o .:? "testDir" <*> o .:? "machineBits" .!= 64 <*> o .:? "generation" .!= defaultGeneration <*> o .:? "minify" .!= False <*> pure native <*> pure verification
      -- An environment attestation is reporting only: it annotates the
      -- evidence and never changes what is compiled or how a law is
      -- discharged. ref:DEC-environment-attestation
      -- The outcome lawspec test recorded for each law in the attestation's
      -- run, by law; it links a planned native check to a completed run.
      outcomes <- o .:? "attestedOutcomes" .!= M.empty
      attestation <- traverse parseAttestation <$> o .:? "attestation"
      pure (request', (Project rootPackage dependencies, packages), fmap (fmap (\a -> (a, outcomes))) attestation)

verificationKeys :: Maybe V.Verification -> [TestEntry] -> [TestEntry]
verificationKeys Nothing entries = entries
verificationKeys (Just config) entries = [entry { entryKey = digestHex (digestString (entryKey entry ++ show config)) } | entry <- entries]

plannedCore :: C.Program -> Either [Diagnostic] Plan -> C.Program
plannedCore core (Right plan) = core { C.programUnits = map plannedUnit (plannedUnits plan) }
plannedCore core _ = core

withSources :: [Source] -> Value -> Value
withSources sources (Object o) = Object (KM.insert "formattedSources" (toJSON sources) o)
withSources _ value = value

-- | Optional authoring findings do not change admission or law evidence.
withMatchWarnings :: [SourceSyntax] -> Value -> Value
withMatchWarnings syntax (Object value) = Object
  (KM.insert "warnings" (toJSON (concatMap syntaxMatchWarnings syntax))
    (KM.insert "warningAnalysis" (object
      ["kind" .= ("match-reachability" :: String), "complete" .= False,
       "scope" .= ("ordered-pattern-specialization" :: String),
       "reason" .= ("Only structurally eliminated rows are reported; absence of warnings does not prove that every branch is reachable." :: String)]) value))
withMatchWarnings _ value = value

-- Selected law checks are reported separately from completed evidence. This
-- field never claims that an unrun native test passed.
withVerification :: Maybe V.Verification -> Value -> Value
withVerification Nothing value = value
withVerification (Just config) (Object o) = Object (KM.insert "languageProfile" (String "1.0-rc.2")
  (KM.insert "verification" (object
    [ "layers" .= V.verificationLayers config
    , "selection" .= (if null (V.verificationLayers config) then "no-selected-checks" else "selected-checks" :: String)
    , "intrinsicDefinitionChecks" .= True ]) o))
withVerification _ value = value

-- | The evidence an environment attestation touches, with where its tests ran,
-- and the attestation itself as the report reads it.
withAttestation :: Maybe (Attestation, M.Map String String) -> C.Program -> [Obligation] -> Value -> Value
withAttestation (Just (attestation, outcomes)) core obligations (Object o) = Object
  $ KM.insert "attestation" (attestationView attestation outcomes core obligations)
  $ maybe o (\items -> KM.insert "evidence" items o) annotated
  where
    annotated = case KM.lookup "evidence" o of
      Just (Array items) -> Just (toJSON (zipWith annotate (toList items) (attestedFields attestation outcomes core obligations)))
      _ -> Nothing
    annotate (Object item) fields = Object (foldr (\(k, v) -> KM.insert k v) item fields)
    annotate item _ = item
withAttestation _ _ _ value = value

-- | Which generated tests check each law, for running a subset of them.
withTests :: C.Program -> Maybe V.Verification -> Either [Diagnostic] Plan -> [TestEntry] -> Value -> Value
withTests original verification testing entries (Object o) = Object (KM.insert "tests" (toJSON (map entry entries)) o)
  where
    entry e = object $
      [ "law" .= C.idText (entryLaw e), "unit" .= entryUnit e, "label" .= entryLabel e
      , "index" .= entryIndex e, "file" .= entryFile e, "key" .= entryKey e
      , "callsAdapters" .= entryCallsAdapters e, "name" .= entryName e, "tags" .= entryTags e
      , "skip" .= entrySkip e, "knownFailing" .= entryKnownFailing e
      , "parallel" .= entryParallel e ] ++
      ["coverage" .= coverage e] ++
      ["kind" .= kind | Just kind<-[entryKind e]] ++ ["scope" .= scope | Just scope<-[entryScope e]] ++
      ["obligations" .= [object ["declaration" .= C.idText identity,"stage" .= stage] |
        (identity,stage)<-entryObligations e] | not (null (entryObligations e))]
    coverage entry
      | not (null (entryObligations entry)) = object ["kind" .= ("sampled"::String),"scopedQuantifiers" .= False]
      | Right plan <- testing,
        p:_ <- [p | u<-plannedUnits plan,p<-plannedProperties u,
          C.propertyId (plannedProperty p)==entryLaw entry] =
          let examplesOnly=maybe False (\config -> V.selected config V.Examples &&
                not (any (V.selected config) [V.Exhaustive,V.Property])) verification
              kind | examplesOnly="examples"
                   | Just _ <- finiteCases p="finite-inputs"
                   | otherwise="sampled"
              count | examplesOnly=Just (length (C.propertyExamples (plannedProperty p)))
                    | otherwise=length <$> finiteCases p
          in object (["kind" .= (kind::String),
                "scopedQuantifiers" .= scoped entry] ++
              ["cases" .= n | Just n<-[count]])
      | otherwise=object ["kind" .= ("sampled"::String),"scopedQuantifiers" .= True]
    scoped entry=case [C.hasLogicalQuantifier (C.propertyBody property) |
      unit<-C.programUnits original,property<-C.unitProperties unit,C.propertyId property==entryLaw entry] of
        value:_ -> value
        [] -> True
withTests _ _ _ _ value = value

-- The harness's benchmarks and the tests that measure them.
withBenchmarks :: [BenchmarkEntry] -> Value -> Value
withBenchmarks entries (Object o) = Object (KM.insert "benchmarks" (toJSON (map entry entries)) o)
  where
    entry e = object [ "unit" .= benchmarkUnit e, "benchmark" .= benchmarkName e, "file" .= benchmarkFile e, "name" .= benchmarkTest e ]
withBenchmarks _ value = value

-- | Z3 tasks for model laws the explicit search left open (induction,
-- Spacer and its re-checks, a bounded run), and, given the host's answers
-- (modelResults), their settled evidence (modelEvidence).
withModelTasks :: [Unit] -> C.Program -> [Obligation] -> [(String, ModelProof.Answer)] -> Value -> Value
withModelTasks us core evidence answers (Object response) =
  let open = [obligationDeclaration o | o <- evidence, obligationStage o == "law", obligationStatus o `elem` [Incomplete, Unsupported]]
      tasks = ModelProof.modelTasks us core open answers
      settled = if null answers then [] else ModelProof.settleModel us core tasks answers
      rows = [ object [ "owner" .= C.idText (runUnit run), "declaration" .= C.idText (runLaw run), "stage" .= ("law" :: String)
                      , "status" .= statusName (runStatus run), "reason" .= runReason run, "claim" .= Null ] | run <- settled ]
      refuted = [ Diagnostic "refuted" (C.idText (runLaw run) ++ ": " ++ runReason run) Nothing | run <- settled, runStatus run == Refuted ]
      existing = case KM.lookup "diagnostics" response of Just (Array ds) -> toList ds; _ -> []
      view (owner, law, ts) = object
        [ "owner" .= C.idText owner, "declaration" .= C.idText law
        , "tasks" .= [ object [ "fingerprint" .= ModelProof.taskFingerprint t, "kind" .= ModelProof.taskKind t
                              , "script" .= ModelProof.taskScript t, "inputs" .= ModelProof.taskInputs t ] | t <- ts ] ]
  in Object (KM.insert "modelTasks" (toJSON (map view tasks)) $ KM.insert "modelEvidence" (toJSON rows) $
       (if null refuted then id else KM.insert "diagnostics" (toJSON (existing ++ map toJSON refuted))) response)
withModelTasks _ _ _ _ value = value

failure :: [Diagnostic] -> Value
failure ds = object ["schemaVersion" .= (5 :: Int), "diagnostics" .= ds]

type Stages = ([Unit], [Expanded], C.Program, BindingPlan, ([Obligation], [Analysis.Row]), [(Package, [String])], Either [Diagnostic] Plan)

stages :: Project -> [Package] -> [Source] -> Int -> Generation -> NativeRequest -> Maybe V.Verification -> Either Value Stages
stages project packages sources bits settings native verification =
  fst <$> stagesWithInput (verification /= Nothing) False project packages sources bits settings native verification

stagesWithInput :: Bool -> Bool -> Project -> [Package] -> [Source] -> Int -> Generation -> NativeRequest -> Maybe V.Verification -> Either Value (Stages,[SourceSyntax])
stagesWithInput canonical capture project packages sources bits settings native verification = case preparePackagesWithOrigins canonical project packages sources of
  Left ds -> Left (failure ds)
  Right (allSources,origins,visible,referenceUnit,described) -> case
    compileWithSourceOrigins origins capture canonical referenceUnit visible bits settings allSources of
    Left ds -> Left (failure (versionedDiagnostics described ds))
    Right (us,es,syntax) -> case elaborateCanonical bits us es of
      Left ds -> Left (failure (versionedDiagnostics described ds))
      Right core -> case resolveNativeRequest core native of
        Left message -> Left (failure [Diagnostic "native-binding" message Nothing])
        Right bindings -> case dischargeReporting verification core of
          Left ds -> Left (failure ds)
          Right evidence -> case elaborateClaims bits us core <* proofSettings us of
            Left ds -> Left (failure ds)
            -- The laws about each function, checked together, by default
            -- whenever proof or exhaustive checking is selected.
            Right claims -> let rows = Analysis.analyse core claims in
              -- Laws about a model's runs, checked over its reference by an
              -- explicit-state search when proof, exhaustive or model
              -- checking is selected.
              let checking = maybe True (\config -> any (V.selected config) [V.Proof, V.Exhaustive, V.Model]) verification in
              case (++) <$> modelLawEvidence checking us core <*> historyLawEvidence checking us core of
                Left ds -> Left (failure ds)
                Right modelEvidence ->
                  Right ((us, es, core, bindings, (evidence ++ modelEvidence, rows), described, maybe planTesting planTestingWith verification core),syntax)

-- | The request without the fields that only select a method, target or layout.
sharedRequest :: B.ByteString -> String
sharedRequest bytes = case decode bytes of
  Just (Object o) -> BC.unpack (encode (Object (foldr (KM.delete . K.fromString) o
    ["method", "target", "sourceDir", "testDir", "minify", "cacheDirectory", "law", "view", "evidence", "attestation", "attestedOutcomes", "proofCounterexamples", "now", "projectVersion", "analysisResults", "modelResults"])))
  _ -> BC.unpack bytes

-- | Two entries: each holds a whole compiled program and its plan.
stagesTable :: Table (Either Value Stages)
stagesTable = unsafePerformIO (newTable 2 (const 1))
{-# NOINLINE stagesTable #-}

-- Syntax inventory is captured separately for authoring consumers.
syntaxStagesTable :: Table (Either Value (Stages,[SourceSyntax]))
syntaxStagesTable = unsafePerformIO (newTable 2 (const 1))
{-# NOINLINE syntaxStagesTable #-}
