-- | Versioned JSON codec for native and legacy consumers. Typed compilation,
-- formatting and discovery services also feed the component interface, so their
-- validation does not depend on an external request encoding.
-- ref:DEC-wasm-distribution ref:DEC-haskell-application-port
module LawSpec.Api (dispatch, sharedRequest) where

import Control.Monad (unless)
import Data.Aeson
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (parseEither, parseMaybe)
import qualified Data.ByteString.Lazy as B
import qualified Data.ByteString.Lazy.Char8 as BC
import Data.Foldable (toList)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import LawSpec.Attestation (Attestation, attestationView, attestedFields, parseAttestation)
import qualified LawSpec.Authoring as Authoring
import LawSpec.Compile (prettyExpanded)
import qualified LawSpec.Component as Component
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Counterexample as Counterexample
import LawSpec.Core.Evidence (Obligation (..), Status (..), statusName)
import qualified LawSpec.Core.LawAnalysis as Analysis
import qualified LawSpec.Core.LawTasks as Tasks
import qualified LawSpec.Core.Smt as Smt
import qualified LawSpec.Core.Verification as V
import LawSpec.CoreEmit (emitPlanWithNativeOptions)
import LawSpec.Digest (digestHex, digestString)
import LawSpec.Discharge (bindingEvidence, defaultHandlerEvidence, refutations, showValue)
import LawSpec.Explain (ExplainOptions (..), View (..), explainResult, parseView)
import LawSpec.Frontend (sourcePropertyId)
import LawSpec.LawClaims (Expiry (..), analysisEvidence, analysisTaskViews, elaborateClaims, settleAnalysis)
import LawSpec.Memo (CacheFailure (..), Progress (..), Table, memoized, newPersistentTable, newTable, noProgress, staged, withRequest)
import LawSpec.Model
import LawSpec.ModelLaws (ModelRun (..))
import qualified LawSpec.ModelProof as ModelProof
import qualified LawSpec.NativeInterface as NativeInterface
import LawSpec.NativeRequest
import LawSpec.Packages
import LawSpec.ProofSettings (proofSettings)
import LawSpec.Public (obligationView, programView)
import LawSpec.Service.Compilation (Stages, stages, stagesWithInput)
import LawSpec.Service.Formatting (formatCompiled, formatSyntax)
import LawSpec.SourceSyntax (SourceSyntax (..))
import LawSpec.SourceText (formatSourcesUsing)
import LawSpec.TargetOptions (TargetOptions, generatedTestDirectory, noTargetOptions, placeByOwnership, releaseProblems, targetOptions)
import LawSpec.Targets (artifactTargets)
import qualified LawSpec.Core.Vacuity as Vacuity
import LawSpec.TestManifest (BenchmarkEntry (..), TestEntry (..), benchmarkManifest, executableEntries, testManifestWithBindings)
import LawSpec.ActorRuntime (actorSettings, defaultActorSettings)
import LawSpec.Testing (Plan (..), PlannedProperty (..), PlannedUnit (..), finiteCases)
import qualified LawSpec.Testing.Budget as Budget
import System.IO.Unsafe (unsafePerformIO)

-- | Decode external requests and render their established response shapes.
-- Shared work is memoised so a host asking for several targets compiles once.
-- ref:DEC-incremental-compilation
dispatch :: B.ByteString -> B.ByteString
dispatch bytes
  | Just (Object o) <- decode bytes,
    Just (String "prelude") <- KM.lookup "method" o =
      encode $ either failure toJSON $ Authoring.queryPrelude $ case KM.lookup "query" o of
        Nothing -> Authoring.PreludeAll
        Just (String query) -> Authoring.PreludeMatching (T.unpack query)
        _ -> Authoring.PreludeInvalid
  | Just value <- decode bytes, Just result <- Component.componentRequest value = encode result
  | otherwise = reportingCache $ withRequest cacheDirectory progress requestTitle $ staged "response" "" $ encode $ versioned $ case eitherDecode bytes >>= parseEither request of
      Left err -> failure [Diagnostic "request" err Nothing]
      Right (_, _, Left err) -> failure [Diagnostic "attestation" err Nothing]
      Right ((method, sources, _, _, _, _, _, _, _, _), (project, packages), Right _)
        | method == "format",
          not formatCompilation ->
            either
              failure
              ( \formatted ->
                  object
                    [ "diagnostics" .= ([] :: [Diagnostic]),
                      "formattedSources" .= formatted,
                      "languageProfile" .= ("1.0-rc.2" :: String)
                    ]
              )
              (formatSourcesUsing (formatSyntax project packages) sources)
      -- An unknown or removed explanation view fails before compilation.
      Right ((method, _, _, _, _, _, _, _, _, _), _, _)
        | method == "explain",
          Left err <- explainOptions ->
            failure [Diagnostic "explain" err Nothing]
      Right ((method, sources, target, sourceDir, testDir, bits, settings, minify, native, verification), (project, packages), Right attestation) ->
        -- Typed compilation is shared across targets. SMT task preparation has a
        -- separate key because it prepares, rather than executes, optional proofs.
        let taskMethod = method == "proofTasks"
            -- Task preparation does not run the older optional law prover. Intrinsic
            -- definition admission remains in compilation, independently of this.
            stageVerification =
              if taskMethod
                then
                  fmap
                    ( \config ->
                        V.withLayers
                          (filter (/= V.Proof) (V.verificationLayers config)) config
                    )
                    verification
                else verification
            stageKey = (if taskMethod then "smt-task-preparation:" else "") ++ sharedRequest bytes
         in case ( if method == "format" || matchWarningsRequested || adviceRequested
                     then
                       memoized
                         syntaxStagesTable
                         ("canonical:" ++ stageKey)
                         (stagesWithInput True True project packages sources bits settings emptyNativeRequest stageVerification)
                     else fmap (\value -> (value, [])) (memoized stagesTable stageKey (stages project packages sources bits settings emptyNativeRequest stageVerification))
                 ) of
              Left diagnostics -> failure diagnostics
              -- Native bindings differ by target and change nothing before
              -- emission, so the compiled program is shared across targets
              -- and each request resolves its own bindings against it.
              Right ((us, es, core, _, (lawEvidence, analysisRows), described, checkedPlan), syntax) ->
                let plan = checkedPlan >>= withActorSettings target bytes
                    -- Generated directories and the release are the target's
                    -- build options: they move or refuse emitted files and
                    -- never change the checked program.
                    options = requestTargetOptions target sourceDir testDir bytes
                    generatedTests = generatedTestDirectory testDir (either (const noTargetOptions) id options)
                    placed = placedArtifacts target sourceDir testDir options
                 in
                either failure id $ (either (\message -> Left [Diagnostic "native-binding" message Nothing]) Right (resolveNativeRequest core native) >>=) $ \bindings ->
                  fmap
                    ( \analysed ->
                        let evidence = lawEvidence ++ map fst analysed
                         in withExemptions analysed $
                              let pending item
                                    | method == "proofTasks",
                                      maybe False (`V.selected` V.Proof) verification,
                                      obligationStage item == "law",
                                      obligationStatus item == NotVerified =
                                        case [ why
                                             | unit <- C.programUnits core,
                                               law <- C.unitProperties unit,
                                               C.propertyId law == obligationDeclaration item,
                                               Just why <- [C.harnessKnownDiscrepancy (C.propertyHarness law)]
                                             ] of
                                          why : _ -> item {obligationStatus = KnownDiscrepancy, obligationReason = "marked known discrepancy: " ++ why ++ "; human review must determine whether the specification, implementation, or both need correction"}
                                          [] -> item {obligationStatus = Planned, obligationReason = "an SMT proof task is requested; no solver execution has completed"}
                                    | otherwise = item
                                  obligations = map pending evidence ++ bindingEvidence bindings ++ defaultHandlerEvidence core bindings
                                  -- A refuted law keeps its row and fails the request.
                                  result files =
                                    withGoEmbeddingWarnings target method
                                      $ withSamplingWarnings
                                      $ withAuthoring syntax core
                                      $ withRefutations (refutations core obligations)
                                      $ (if matchWarningsRequested then withMatchWarnings syntax else id)
                                      $ withAttestation attestation core obligations (withVerification verification (withPackages project described (programView settings us (map prettyExpanded es) files obligations (C.lowerProgramFields core))))
                               in case method of
                                    "check" -> result []
                                    "advise" -> result []
                                    "expand" -> result []
                                    -- Presentation of the expanded laws; it changes no obligation.
                                    "explain" | Right options <- explainOptions -> case result [] of
                                      Object response ->
                                        either
                                          (\err -> failure [Diagnostic "explain" err Nothing])
                                          ( \explained -> case explained of
                                              Object e -> Object (KM.insert "diagnostics" (fromMaybe (toJSON ([] :: [Diagnostic])) (KM.lookup "diagnostics" response)) e)
                                              other -> other
                                          )
                                          (explainResult options (Object response))
                                      response -> response
                                    "proofTasks"
                                      | Just selection <- verification ->
                                          if V.selected selection V.Proof
                                            then
                                              either
                                                failure
                                                ( \tasks -> case result [] of
                                                    Object response ->
                                                      withModelTasks
                                                        us
                                                        core
                                                        evidence
                                                        modelAnswers
                                                        ( withAnalysisTasks
                                                            us
                                                            core
                                                            analysisRows
                                                            (Object (withCounterexampleChecks core tasks (KM.insert "proofTasks" (toJSON tasks) response)))
                                                        )
                                                    response -> response
                                                )
                                                (proofSettings us >>= \settings -> Smt.proofTasksWith settings core)
                                            else case result [] of
                                              Object response -> Object (KM.insert "proofTasks" (toJSON ([] :: [Smt.ProofTask])) response)
                                              response -> response
                                    "proofTasks" -> failure [Diagnostic "language-profile" "proofTasks requires API schema 5 and languageProfile 1.0-rc.2" Nothing]
                                    "format"
                                      | verification /= Nothing ->
                                          either
                                            failure
                                            (\formattedSources -> withSources formattedSources (result []))
                                            (formatCompiled project packages sources bits settings syntax)
                                    "format" -> failure [Diagnostic "language-profile" "format requires API schema 5 and languageProfile 1.0-rc.2" Nothing]
                                    "inspect"
                                      | target `elem` artifactTargets,
                                        native /= emptyNativeRequest ->
                                          failure [Diagnostic "native-binding" "artifact targets do not support native bindings" Nothing]
                                    "inspect" -> case plan of
                                      Left ds -> failure ds
                                      Right selectedPlan -> case placed plan (staged "emit" target (emitPlanWithNativeOptions False target sourceDir testDir bindings selectedPlan)) of
                                        Left ds -> failure ds
                                        -- The compact layout only supplies digests, by which a host
                                        -- recognizes a generated file written with --minify. They are
                                        -- kept under a key of everything emission reads, so an
                                        -- unchanged project lays its files out compactly once.
                                        Right files -> case memoized
                                          compactDigestTable
                                          (digestHex (digestString (emissionRequest bytes)))
                                          ( fmap
                                              (\compact -> [(artifactPath file, digestHex (digestString (artifactContent file))) | file <- compact ++ networkArtifacts native])
                                              (placed plan (staged "emit-compact" target (emitPlanWithNativeOptions True target sourceDir testDir bindings selectedPlan)))
                                          ) of
                                          Left ds -> failure ds
                                          Right compact -> case NativeInterface.interfaceView target bindings selectedPlan (files ++ networkArtifacts native) compact of
                                            Left err -> failure [Diagnostic "native-interface" err Nothing]
                                            Right view -> case result (files ++ networkArtifacts native) of
                                              Object fields -> Object (KM.insert "interface" view fields)
                                              response -> response
                                    "planGeneration"
                                      | target `elem` artifactTargets,
                                        native /= emptyNativeRequest ->
                                          failure [Diagnostic "native-binding" "artifact targets do not support native bindings" Nothing]
                                    "planGeneration" ->
                                      either
                                        failure
                                        ( withBenchmarks (benchmarkManifest target generatedTests core)
                                            . withTests
                                              target
                                              core
                                              verification
                                              plan
                                              ( verificationKeys
                                                  verification
                                                  . actorKeys plan
                                                  $ ( nativeBudgetKeys
                                                      target
                                                      plan
                                                      ( either
                                                          (const id)
                                                          executableEntries
                                                          plan
                                                          ( testManifestWithBindings
                                                              (maybe True (`V.selected` V.Model) verification)
                                                              bindings
                                                              target
                                                              generatedTests
                                                              (plannedCore core plan)
                                                          )
                                                      )
                                                  )
                                              )
                                            . result
                                        )
                                        ((++ networkArtifacts native) <$> placed plan (plan >>= staged "emit" target . emitPlanWithNativeOptions minify target sourceDir testDir bindings))
                                    _ -> failure [Diagnostic "request" ("unknown method: " ++ method) Nothing]
                    )
                    ( analysisEvidence
                        (maybe True (\config -> V.selected config V.Exhaustive || V.selected config V.Proof) verification)
                        (maybe True (`V.selected` V.Proof) verification)
                        False
                        expiry
                        analysisRows
                    )
  where
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
    adviceRequested = case decode bytes of
      Just (Object input) | Just (Bool False) <- KM.lookup "advice" input -> False
      _ -> True
    withAuthoring syntax core response@(Object fields) = case decode bytes of
      Just (Object input) | Just (Bool False) <- KM.lookup "advice" input -> response
      _ -> Object (KM.insert "advice" (Authoring.adviceView syntax core) fields)
    withAuthoring _ _ response = response
    -- Where the compiler may keep work between runs; the CLI names one per
    -- project and compiler build. inspect and advise write nothing, whatever
    -- directory their request names (ref:DEC-authoring-advisories), unless
    -- the request also sets cacheAdvisory: a command that already keeps a
    -- cache (check, generate) asks for its advice that way, so the advice
    -- shares the command's work instead of compiling the project again.
    cacheDirectory = case decode bytes of
      Just (Object o)
        | Just (String method) <- KM.lookup "method" o,
          method `elem` ["inspect", "advise"],
          KM.lookup "cacheAdvisory" o /= Just (Bool True) ->
            Nothing
      Just (Object o) | Just (String d) <- KM.lookup "cacheDirectory" o -> Just (T.unpack d)
      _ -> Nothing
    -- An entry the cache could not store changes no result. The response
    -- names the first one, so a host can say why later runs stay cold.
    reportingCache (response, Nothing) = response
    reportingCache (response, Just (CacheFailure path reason)) = case decode response of
      Just (Object fields) -> encode (Object (KM.insert "cacheFailure" (object ["path" .= path, "reason" .= reason]) fields))
      _ -> response
    -- "progress" names what to write on standard error while the request
    -- runs: "lines", "terminal" and "timings", one of them or a list.
    progress = case decode bytes of
      Just (Object o) -> case KM.lookup "progress" o of
        Just (String mode) -> progressOf [mode]
        Just (Array modes) -> progressOf [mode | String mode <- toList modes]
        _ -> noProgress
      _ -> noProgress
    progressOf modes = Progress ("lines" `elem` modes) ("terminal" `elem` modes) ("timings" `elem` modes)
    requestTitle = case decode bytes of
      Just (Object o) -> unwords [T.unpack value | key <- ["method", "target"], Just (String value) <- [KM.lookup key o]]
      _ -> ""
    -- The host's counterexample values, each bound to a task it ran
    -- (LawSpec.Core.Counterexample). The compiler re-derives the query and
    -- re-checks the values; it trusts neither the host nor Z3.
    withCounterexampleChecks core tasks response = case decode bytes of
      Just (Object o)
        | Just (Array asked) <- KM.lookup "proofCounterexamples" o ->
            KM.insert "counterexampleChecks" (toJSON [counterexampleCheck core tasks item | item <- toList asked]) response
      _ -> response
    counterexampleCheck core tasks item = case item of
      Object o
        | Just (String owner) <- KM.lookup "owner" o,
          Just (String law) <- KM.lookup "declaration" o,
          Just (String fingerprint) <- KM.lookup "taskFingerprint" o,
          Just (String answer) <- KM.lookup "values" o ->
            let identity = ["owner" .= owner, "declaration" .= law, "taskFingerprint" .= fingerprint]
             in case [ t
                     | t <- tasks,
                       C.idText (Smt.taskOwner t) == T.unpack owner,
                       C.idText (Smt.taskLaw t) == T.unpack law,
                       Smt.taskFingerprint t == T.unpack fingerprint
                     ] of
                  task : _ -> object (identity ++ counterexampleView (Counterexample.validateCounterexample core task (T.unpack answer)))
                  [] ->
                    object
                      ( identity
                          ++ [ "status" .= ("incomplete" :: String),
                               "reason" .= ("the counterexample is bound to a task this program does not have" :: String)
                             ]
                      )
      _ -> object ["status" .= ("incomplete" :: String), "reason" .= ("malformed counterexample request" :: String)]
    counterexampleView check =
      ["status" .= Counterexample.checkStatus check] ++ case check of
        Counterexample.Refuted inputs why -> ["reason" .= why, "inputs" .= shown inputs]
        Counterexample.ModelNotConfirmed inputs why -> ["reason" .= why, "inputs" .= shown inputs]
        Counterexample.CheckIncomplete why -> ["reason" .= why]
    shown inputs = [object ["name" .= C.binderName (C.quantifiedBinder q), "value" .= showValue v] | (q, v) <- inputs]
    -- The host's answers to model tasks, by fingerprint.
    modelAnswers = case decode bytes of
      Just (Object o)
        | Just (Array given) <- KM.lookup "modelResults" o ->
            [ (T.unpack fp, ModelProof.Answer (T.unpack outcome) (text "values" a) (text "invariant" a) (inputNames a))
            | Object a <- toList given,
              Just (String fp) <- [KM.lookup "fingerprint" a],
              Just (String outcome) <- [KM.lookup "outcome" a]
            ]
      _ -> []
      where
        inputNames a = case KM.lookup "inputs" a of
          Just (Array ns) -> traverse (\v -> case v of String n -> Just (T.unpack n); _ -> Nothing) (toList ns)
          _ -> Nothing
        text k a = case KM.lookup k a of Just (String v) -> T.unpack v; _ -> ""
    -- Explain the same capability decision used by typed handler emission.
    -- The dynamic evaluator remains available; no unchecked setter is invented.
    withGoEmbeddingWarnings "go" "planGeneration" (Object response) =
      let rows =
            [ object
                [ "code" .= ("go-handler-embedding" :: String),
                  "severity" .= ("warning" :: String),
                  "at" .= Null,
                  "message" .= ("Go handler " ++ name ++ " uses checked dynamic execution; Start/State/SetState embedding entry points are unavailable: " ++ why)
                ]
            | Just (Array units) <- [KM.lookup "units" response],
              Object unit <- toList units,
              Just (Array handlers) <- [KM.lookup "handlers" unit],
              Object handler <- toList handlers,
              Just (String handlerName) <- [KM.lookup "name" handler],
              let name = T.unpack handlerName,
              Just (Object capability) <- [KM.lookup "goEmbedding" handler],
              KM.lookup "available" capability == Just (Bool False),
              Just (Array reasons) <- [KM.lookup "reasons" capability],
              let why = unwords [T.unpack reason | String reason <- toList reasons]
            ]
          existing = case KM.lookup "warnings" response of Just (Array values) -> toList values; _ -> []
       in Object (if null rows then response else KM.insert "warnings" (toJSON (existing ++ rows)) response)
    withGoEmbeddingWarnings _ _ response = response
    -- A scoped quantifier that bounded sampling can refute and never
    -- establish (law.sampledQuantifiers) is reported when the law is
    -- compiled, before a generated test fails with
    -- quantifier-search-incomplete. A warning: the law still compiles and its
    -- evidence is unchanged.
    withSamplingWarnings (Object response) =
      let rows =
            [ object
                [ "code" .= ("quantifier-decided-by-sampling" :: String),
                  "severity" .= ("warning" :: String),
                  "at" .= fromMaybe Null (KM.lookup "location" law),
                  "message" .= samplingWarning (text "owner" law ++ "::" ++ text "name" law) kind negated (text "name" binder)
                ]
            | Just (Array laws) <- [KM.lookup "laws" response],
              Object law <- toList laws,
              Just (Array sampled) <- [KM.lookup "sampledQuantifiers" law],
              Object quantifier <- toList sampled,
              Just (Object binder) <- [KM.lookup "binder" quantifier],
              let kind = text "kind" quantifier
                  negated = KM.lookup "negated" quantifier == Just (Bool True)
            ]
          text key fields = case KM.lookup key fields of Just (String value) -> T.unpack value; _ -> ""
          existing = case KM.lookup "warnings" response of Just (Array values) -> toList values; _ -> []
       in Object (if null rows then response else KM.insert "warnings" (toJSON (existing ++ rows)) response)
    withSamplingWarnings response = response
    matchWarningsRequested = case decode bytes of
      Just (Object o) -> KM.lookup "warnMatches" o == Just (Bool True)
      _ -> False
    -- The law-set checks the compiler left undecided are Z3 tasks; their
    -- answers, sent back as analysisResults, settle them
    -- (LawSpec.LawClaims.settleAnalysis).
    withAnalysisTasks us core rows (Object response) =
      let claimsOf = elaborateClaims (C.programMachineBits core) us core
          withTasks = KM.insert "analysisTasks" (toJSON (either (const []) (\claims -> analysisTaskViews core claims rows) claimsOf)) response
          answers = case decode bytes of
            Just (Object o)
              | Just (Array given) <- KM.lookup "analysisResults" o ->
                  Just
                    [ (T.unpack fp, Tasks.Answer (T.unpack outcome) (maybe "" T.unpack values) inputNames)
                    | Object a <- toList given,
                      Just (String fp) <- [KM.lookup "fingerprint" a],
                      Just (String outcome) <- [KM.lookup "outcome" a],
                      let values = case KM.lookup "values" a of Just (String v) -> Just v; _ -> Nothing
                          inputNames = case KM.lookup "inputs" a of
                            Just (Array names) -> Just [T.unpack name | String name <- toList names]
                            _ -> Nothing
                    ]
            _ -> Nothing
       in case answers of
            Nothing -> Object withTasks
            Just given -> case claimsOf >>= \claims -> settleAnalysis True expiry claims core rows given of
              Left ds -> failure ds
              Right (evidence, verdicts) ->
                let refuted = refutations core (map fst evidence)
                    existing = case KM.lookup "diagnostics" withTasks of Just (Array ds) -> toList ds; _ -> []
                 in Object
                      ( KM.insert
                          "analysisEvidence"
                          ( toJSON
                              [ case (obligationView [] o, view) of
                                  (Object row, Just v) -> Object (KM.insert "exemption" v row)
                                  (row, _) -> row
                              | (o, view) <- evidence
                              ]
                          )
                          ( KM.insert
                              "analysisChecks"
                              (toJSON verdicts)
                              (KM.insert "diagnostics" (toJSON (existing ++ map toJSON refuted)) withTasks)
                          )
                      )
    withAnalysisTasks _ _ _ response = response
    -- An exempted or expired check shows its exemption.
    withExemptions analysed (Object value) =
      let annotated = case KM.lookup "evidence" value of
            Just (Array rows) -> KM.insert "evidence" (Array (fmap (attach analysed) rows)) value
            _ -> value
          expired =
            [ object
                [ "code" .= ("exemption-expired" :: String),
                  "severity" .= ("warning" :: String),
                  "at" .= (Nothing :: Maybe Location),
                  "message"
                    .= ( "The exemption for "
                           ++ C.idText (obligationDeclaration item)
                           ++ " ("
                           ++ obligationStage item
                           ++ ") has expired"
                           ++ deadline
                           ++ "; it no longer excuses this check. "
                           ++ "Remove it or establish the obligation independently."
                       )
                ]
            | (item, Just (Object exemption)) <- analysed,
              KM.lookup "expired" exemption == Just (Bool True),
              let deadline = case KM.lookup "until" exemption of
                    Just (String until) -> " (until " ++ T.unpack until ++ ")"
                    _ -> ""
            ]
          existing = case KM.lookup "warnings" annotated of
            Just (Array warnings) -> toList warnings
            _ -> []
       in Object (if null expired then annotated else KM.insert "warnings" (toJSON (existing ++ expired)) annotated)
    withExemptions _ value = value
    attach analysed row = case row of
      Object o
        | Just view <-
            lookup
              (KM.lookup "declaration" o, KM.lookup "stage" o)
              [ ((Just (toJSON (C.idText (obligationDeclaration item))), Just (toJSON (obligationStage item))), v)
              | (item, Just v) <- analysed
              ] ->
            Object (KM.insert "exemption" view o)
      _ -> row
    expiry = case decode bytes of
      Just (Object o) ->
        Expiry
          ( case (KM.lookup "projectVersion" o, KM.lookup "package" o) of
              (Just (String v), _) -> Just (T.unpack v)
              (_, Just (Object p)) | Just (String v) <- KM.lookup "version" p -> Just (T.unpack v)
              _ -> Nothing
          )
          (case KM.lookup "now" o of Just (String t) -> Just (T.unpack t); _ -> Nothing)
      _ -> Expiry Nothing Nothing
    withRefutations [] value = value
    withRefutations ds (Object value) = Object (KM.insert "diagnostics" (toJSON ds) value)
    withRefutations _ value = value
    withPackages project described (Object value) =
      Object (foldr (\(k, v) -> KM.insert k v) value (packagesView project described))
    withPackages _ _ value = value
    versioned (Object value) = Object (KM.insert "schemaVersion" (toJSON (5 :: Int)) value)
    versioned value = value
    request = withObject "request" $ \o -> do
      version <- o .:? "schemaVersion" .!= (5 :: Int)
      unless (version == 5) (fail "LawSpec requires API schemaVersion 5 and languageProfile 1.0-rc.2")
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

-- The JVM/Go/Haskell harness currently shares its node budget across laws.
-- Reuse must keep this real sampling input until the harness makes it local.
nativeBudgetKeys :: String -> Either [Diagnostic] Plan -> [TestEntry] -> [TestEntry]
nativeBudgetKeys target (Right plan) entries
  | Just budget <- Budget.sharedNativeBudget target plan =
      [entry {entryKey = digestHex (digestString (show (entryKey entry, "native-node-budget", budget)))} | entry <- entries]
nativeBudgetKeys _ _ entries = entries

-- | A target's generated directories and release, read from the request as
-- its actor settings are. A null field is an absent one.
requestTargetOptions :: String -> Maybe String -> Maybe String -> B.ByteString -> Either [Diagnostic] TargetOptions
requestTargetOptions target sourceDir testDir bytes =
  either
    (\problems -> Left [Diagnostic code problem Nothing | (code, problem) <- problems])
    Right
    (targetOptions target sourceDir testDir (text <$> field "generatedSourceDir") (text <$> field "generatedTestDir") (whole <$> field "release"))
  where
    field name = case decode bytes of
      Just (Object o) | Just value <- KM.lookup name o, value /= Null -> Just value
      _ -> Nothing
    text (String value) = Just (T.unpack value)
    text _ = Nothing
    whole = parseMaybe parseJSON

-- | Emitted files at the paths their ownership gives them, unless the
-- program needs a newer release than the target compiles at.
placedArtifacts ::
  String ->
  Maybe String ->
  Maybe String ->
  Either [Diagnostic] TargetOptions ->
  Either [Diagnostic] Plan ->
  Either [Diagnostic] [Artifact] ->
  Either [Diagnostic] [Artifact]
placedArtifacts target sourceDir testDir given plan emitted = do
  options <- given
  units <- map (C.idText . C.unitId . plannedUnit) . plannedUnits <$> plan
  case releaseProblems target options units of
    [] -> pure ()
    problems -> Left [Diagnostic "release" problem Nothing | problem <- problems]
  files <- emitted
  either (\problem -> Left [Diagnostic "collision" problem Nothing]) Right (placeByOwnership target sourceDir testDir options files)

-- | A target's actor runtime (lawspec.edn's :actors) is a generation choice:
-- it changes the generated actors and scaffolds, never the checked program.
-- ref:DEC-pekko-runtime
withActorSettings :: String -> B.ByteString -> Plan -> Either [Diagnostic] Plan
withActorSettings target bytes plan =
  either
    (\problems -> Left [Diagnostic "actors" problem Nothing | problem <- problems])
    (\settings -> Right plan {planActors = settings})
    (actorSettings "actors" (if null target then Nothing else Just target) given)
  where
    given = case decode bytes of
      Just (Object o) -> KM.lookup "actors" o
      _ -> Nothing

-- | Results on another actor runtime are other results; the default keeps
-- its existing keys.
actorKeys :: Either [Diagnostic] Plan -> [TestEntry] -> [TestEntry]
actorKeys (Right plan) entries
  | planActors plan /= defaultActorSettings =
      [entry {entryKey = digestHex (digestString (entryKey entry ++ show (planActors plan)))} | entry <- entries]
actorKeys _ entries = entries

verificationKeys :: Maybe V.Verification -> [TestEntry] -> [TestEntry]
verificationKeys Nothing entries = entries
verificationKeys (Just config) entries = [entry {entryKey = digestHex (digestString (entryKey entry ++ show config))} | entry <- entries]

plannedCore :: C.Program -> Either [Diagnostic] Plan -> C.Program
plannedCore core (Right plan) = core {C.programUnits = map plannedUnit (plannedUnits plan)}
plannedCore core _ = core

-- | Why a scoped quantifier cannot be established by generated tests, and the
-- rewrite that makes it a generated input.
samplingWarning :: String -> String -> Bool -> String -> String
samplingWarning law kind negated name =
  "law " ++ law ++ ": the quantifier \"" ++ written ++ "\" is nested inside the definition"
    ++ (if negated then ", under a negation" else "")
    ++ ", so generated tests decide it by bounded sampling. Sampling can refute it and can never establish it:"
    ++ " when no counterexample is found the result is unknown and the test fails with quantifier-search-incomplete."
    ++ " Move it to the front of the definition (for all (" ++ name ++ " of type ...) => ... end for all),"
    ++ " where " ++ name ++ " becomes a generated input of the law"
    ++ (if kind == "forall" then "; a conjunct beside it moves inside its body." else "; state the claim as a universal there.")
  where written = (if kind == "forall" then "for all " else "there exists ") ++ name

withSources :: [Source] -> Value -> Value
withSources sources (Object o) = Object (KM.insert "formattedSources" (toJSON sources) o)
withSources _ value = value

-- | Optional authoring findings do not change admission or law evidence.
withMatchWarnings :: [SourceSyntax] -> Value -> Value
withMatchWarnings syntax (Object value) =
  Object
    ( KM.insert
        "warnings"
        (toJSON (concatMap syntaxMatchWarnings syntax))
        ( KM.insert
            "warningAnalysis"
            ( object
                [ "kind" .= ("match-reachability" :: String),
                  "complete" .= False,
                  "scope" .= ("ordered-pattern-specialization" :: String),
                  "reason" .= ("Only structurally eliminated rows are reported; absence of warnings does not prove that every branch is reachable." :: String)
                ]
            )
            value
        )
    )
withMatchWarnings _ value = value

-- Selected law checks are reported separately from completed evidence. This
-- field never claims that an unrun native test passed.
withVerification :: Maybe V.Verification -> Value -> Value
withVerification Nothing value = value
withVerification (Just config) (Object o) =
  Object
    ( KM.insert
        "languageProfile"
        (String "1.0-rc.2")
        ( KM.insert
            "verification"
            ( object
                [ "layers" .= V.verificationLayers config,
                  "selection" .= (if null (V.verificationLayers config) then "no-selected-checks" else "selected-checks" :: String),
                  "intrinsicDefinitionChecks" .= True
                ]
            )
            o
        )
    )
withVerification _ value = value

-- | The evidence an environment attestation touches, with where its tests ran,
-- and the attestation itself as the report reads it.
withAttestation :: Maybe (Attestation, M.Map String String) -> C.Program -> [Obligation] -> Value -> Value
withAttestation (Just (attestation, outcomes)) core obligations (Object o) =
  Object
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
withTests :: String -> C.Program -> Maybe V.Verification -> Either [Diagnostic] Plan -> [TestEntry] -> Value -> Value
withTests target original verification testing entries (Object o) = Object (KM.insert "tests" (toJSON (map entry entries)) o)
  where
    -- A law whose claim sits behind guards: how many, whether this target's
    -- generated tests count the cases that reach the consequence, and what
    -- to suggest when none does. ref:DEC-vacuous-outcome
    reach e =
      [ "reach"
          .= object
            [ "guards" .= length guards,
              "measured" .= (target `elem` Vacuity.reachTargets),
              "advice"
                .= [ object ["rule" .= Vacuity.adviceRule advice, "input" .= Vacuity.adviceInput advice, "message" .= Vacuity.adviceMessage advice]
                   | advice <- Vacuity.programGuardAdvice original property
                   ]
            ]
      | null (entryObligations e),
        property : _ <- [[p | unit <- C.programUnits original, p <- C.unitProperties unit, C.propertyId p == entryLaw e]],
        let guards = Vacuity.propositionGuards (C.propertyBody property),
        not (null guards)
      ]
    entry e =
      object $
        [ "law" .= C.idText (entryLaw e),
          "unit" .= entryUnit e,
          "label" .= entryLabel e,
          "index" .= entryIndex e,
          "file" .= entryFile e,
          "key" .= entryKey e,
          "callsAdapters" .= entryCallsAdapters e,
          "name" .= entryName e,
          "tags" .= entryTags e,
          "skip" .= entrySkip e,
          "knownDiscrepancy" .= entryKnownDiscrepancy e,
          "parallel" .= entryParallel e
        ]
          ++ ["coverage" .= coverage e]
          ++ reach e
          ++ ["kind" .= kind | Just kind <- [entryKind e]]
          ++ ["scope" .= scope | Just scope <- [entryScope e]]
          ++ [ "obligations"
                 .= [ object ["declaration" .= C.idText identity, "stage" .= stage]
                    | (identity, stage) <- entryObligations e
                    ]
             | not (null (entryObligations e))
             ]
    coverage entry
      | not (null (entryObligations entry)) = object ["kind" .= ("sampled" :: String), "scopedQuantifiers" .= False]
      | Right plan <- testing,
        p : _ <-
          [ p
          | u <- plannedUnits plan,
            p <- plannedProperties u,
            C.propertyId (plannedProperty p) == entryLaw entry
          ] =
          let examplesOnly =
                maybe
                  False
                  ( \config ->
                      V.selected config V.Examples
                        && not (any (V.selected config) [V.Exhaustive, V.Property])
                  )
                  verification
              kind
                | examplesOnly = "examples"
                | Just _ <- finiteCases p = "finite-inputs"
                | otherwise = "sampled"
              count
                | examplesOnly = Just (length (C.propertyExamples (plannedProperty p)))
                | otherwise = length <$> finiteCases p
           in object
                ( [ "kind" .= (kind :: String),
                    "scopedQuantifiers" .= scoped entry
                  ]
                    ++ ["cases" .= n | Just n <- [count]]
                )
      | otherwise = object ["kind" .= ("sampled" :: String), "scopedQuantifiers" .= True]
    scoped entry = case [ C.hasLogicalQuantifier (C.propertyBody property)
                        | unit <- C.programUnits original,
                          property <- C.unitProperties unit,
                          C.propertyId property == entryLaw entry
                        ] of
      value : _ -> value
      [] -> True
withTests _ _ _ _ _ value = value

-- The harness's benchmarks and the tests that measure them.
withBenchmarks :: [BenchmarkEntry] -> Value -> Value
withBenchmarks entries (Object o) = Object (KM.insert "benchmarks" (toJSON (map entry entries)) o)
  where
    entry e = object ["unit" .= benchmarkUnit e, "benchmark" .= benchmarkName e, "file" .= benchmarkFile e, "name" .= benchmarkTest e]
withBenchmarks _ value = value

-- | Z3 tasks for model laws the explicit search left open (induction,
-- Spacer and its re-checks, a bounded run), and, given the host's answers
-- (modelResults), their settled evidence (modelEvidence).
withModelTasks :: [Unit] -> C.Program -> [Obligation] -> [(String, ModelProof.Answer)] -> Value -> Value
withModelTasks us core evidence answers (Object response) =
  let open = [obligationDeclaration o | o <- evidence, obligationStage o == "law", obligationStatus o `elem` [Incomplete, Unsupported]]
      tasks = ModelProof.modelTasks us core open answers
      settled = if null answers then [] else ModelProof.settleModel us core tasks answers
      rows =
        [ object
            [ "owner" .= C.idText (runUnit run),
              "declaration" .= C.idText (runLaw run),
              "stage" .= ("law" :: String),
              "status" .= statusName (runStatus run),
              "reason" .= runReason run,
              "claim" .= Null
            ]
        | run <- settled
        ]
      refuted = [Diagnostic "refuted" (C.idText (runLaw run) ++ ": " ++ runReason run) Nothing | run <- settled, runStatus run == Refuted]
      existing = case KM.lookup "diagnostics" response of Just (Array ds) -> toList ds; _ -> []
      view (owner, law, ts) =
        object
          [ "owner" .= C.idText owner,
            "declaration" .= C.idText law,
            "tasks"
              .= [ object
                     [ "fingerprint" .= ModelProof.taskFingerprint t,
                       "semanticFingerprint" .= ModelProof.taskSemanticFingerprint t,
                       "kind" .= ModelProof.taskKind t,
                       "script" .= ModelProof.taskScript t,
                       "inputs" .= ModelProof.taskInputs t
                     ]
                 | t <- ts
                 ]
          ]
   in Object
        ( KM.insert "modelChecks" (toJSON [object ["fingerprint" .= fp, "status" .= status, "reason" .= reason] | (fp, status, reason) <- ModelProof.modelAnswerChecks us core tasks answers])
            $ KM.insert "modelTasks" (toJSON (map view tasks))
            $ KM.insert "modelEvidence" (toJSON rows)
            $ (if null refuted then id else KM.insert "diagnostics" (toJSON (existing ++ map toJSON refuted))) response
        )
withModelTasks _ _ _ _ value = value

failure :: [Diagnostic] -> Value
failure ds = object ["schemaVersion" .= (5 :: Int), "diagnostics" .= ds]

-- | The request without the fields that only select a method, target or layout.
sharedRequest :: B.ByteString -> String
sharedRequest bytes = case decode bytes of
  Just (Object o) ->
    BC.unpack
      ( encode
          ( Object
              ( foldr
                  (KM.delete . K.fromString)
                  o
                  ["method", "target", "sourceDir", "testDir", "generatedSourceDir", "generatedTestDir", "release", "minify", "nativeBindings", "cacheDirectory", "cacheAdvisory", "progress", "law", "view", "evidence", "attestation", "attestedOutcomes", "proofCounterexamples", "now", "projectVersion", "analysisResults", "modelResults"]
              )
          )
      )
  _ -> BC.unpack bytes

-- | The request without the fields that emission never reads: everything
-- that decides the checked plan, with the target, its directories, its
-- native bindings and its actor settings.
emissionRequest :: B.ByteString -> String
emissionRequest bytes = case decode bytes of
  Just (Object o) ->
    BC.unpack
      ( encode
          ( Object
              ( foldr
                  (KM.delete . K.fromString)
                  o
                  ["method", "minify", "cacheDirectory", "cacheAdvisory", "progress", "law", "view", "evidence", "attestation", "attestedOutcomes", "proofCounterexamples", "now", "projectVersion", "analysisResults", "modelResults"]
              )
          )
      )
  _ -> BC.unpack bytes

-- | Each generated file's path and SHA-256 in the compact layout.
compactDigestTable :: Table (Either [Diagnostic] [(FilePath, String)])
compactDigestTable = unsafePerformIO (newPersistentTable "inspect-compact" 64 (const 1))
{-# NOINLINE compactDigestTable #-}

-- | Two entries: each holds a whole compiled program and its plan.
stagesTable :: Table (Either [Diagnostic] Stages)
stagesTable = unsafePerformIO (newTable 2 (const 1))
{-# NOINLINE stagesTable #-}

-- Syntax inventory is captured separately for authoring consumers.
syntaxStagesTable :: Table (Either [Diagnostic] (Stages, [SourceSyntax]))
syntaxStagesTable = unsafePerformIO (newTable 2 (const 1))
{-# NOINLINE syntaxStagesTable #-}
