-- | The compiler's one entry point for every host: the native lawspec-core
-- executable, the WASM core the npm package and the documentation site load,
-- and lawspec-dev docs all speak the same JSON request and response, so the
-- eight targets and the two builds cannot drift apart. ref:DEC-wasm-distribution
module LawSpec.Api (dispatch) where
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import Control.Monad (unless)
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString.Lazy as B
import LawSpec.Model
import LawSpec.Digest (digestString, digestHex)
import LawSpec.SourceText (formatSource)
import LawSpec.SourceSyntax (SourceSyntax)
import LawSpec.Compile
import LawSpec.Frontend (elaborate, elaborateCanonical)
import LawSpec.Testing (Plan(..), PlannedUnit(..), planTesting, planTestingWith)
import qualified LawSpec.Core.Verification as V
import qualified LawSpec.Core.Smt as Smt
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Migration as Migration
import LawSpec.MigrationTemplates (SourceTemplates,templateSnapshot)
import LawSpec.MigrationTemplateDomains (withTemplateInputDomains)
import LawSpec.MigrationDomains (domainSnapshot,withTransportDomains)
import LawSpec.MigrationPayloads (payloadCorrespondenceWithPlan)
import LawSpec.Core.PayloadTransport (transportComparisonWithProgram)
import LawSpec.Core.Evidence (Obligation(..), Status(..))
import LawSpec.CoreEmit (emitPlanWithNativeOptions)
import LawSpec.NativeRequest
import LawSpec.Public (programView)
import LawSpec.Packages
import LawSpec.Discharge (dischargeEvidence, dischargeEvidenceWith, bindingEvidence, defaultHandlerEvidence)
import LawSpec.Attestation (Attestation, parseAttestation, attestedFields, attestationView)
import Data.Foldable (toList)
import LawSpec.TestManifest (TestEntry(..), testManifest, BenchmarkEntry(..), benchmarkManifest)
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
  Right (_, _, Left err, _) -> failure [Diagnostic "attestation" err Nothing]
  Right ((method,sources,target,sourceDir,testDir,bits,settings,minify,native,verification),(project,packages),Right attestation,migrated) ->
   if method == "migrationComparison" then comparison migrated
   else if method == "migrationBaseline" then
    case memoized syntaxStagesTable (sharedRequest bytes)
      (stagesWithInput False True project packages sources bits settings native verification) of
      Left response -> response
      Right ((us,es,core,bindings,evidence,described,_,templates),syntax) ->
        let obligations = evidence ++ bindingEvidence bindings ++ defaultHandlerEvidence core bindings
        in withMigrationSemantics False us core templates $ withMigrationSyntax syntax $ withAttestation attestation core obligations $ withVerification verification $
          withPackages project described (programView settings us (map prettyExpanded es) [] obligations (C.lowerProgramFields core))
   else
   -- Typed compilation is shared across targets. SMT task preparation has a
   -- separate key because it prepares, rather than executes, optional proofs.
   let taskMethod = method == "proofTasks"
       -- Task preparation does not run the older optional law prover. Intrinsic
       -- definition admission remains in compilation, independently of this.
       stageVerification = if taskMethod then fmap (\config -> V.Verification
         (filter (/= V.Proof) (V.verificationLayers config))) verification else verification
       stageKey = (if taskMethod then "smt-task-preparation:" else "") ++ sharedRequest bytes
   in case (if snapshotRequested then fst <$> memoized syntaxStagesTable ("canonical:" ++ stageKey)
          (stagesWithInput True True project packages sources bits settings native stageVerification)
        else memoized stagesTable stageKey (stages project packages sources bits settings native stageVerification)) of
    Left response -> response
    Right (us,es,core,bindings,evidence,described,plan,templates) ->
     let pending item | method=="proofTasks", maybe False (`V.selected` V.Proof) verification,
                        obligationStage item=="law", obligationStatus item==NotVerified =
                          case [why | unit<-C.programUnits core, law<-C.unitProperties unit,
                            C.propertyId law==obligationDeclaration item,
                            Just why<-[C.harnessKnownFailing (C.propertyHarness law)]] of
                            why:_ -> item{obligationStatus=KnownFailing,obligationReason="marked known failing: "++why}
                            [] -> item{obligationStatus=Planned,obligationReason="an SMT proof task is requested; no solver execution has completed"}
                      | otherwise = item
         obligations = map pending evidence ++ bindingEvidence bindings ++ defaultHandlerEvidence core bindings
         result files = (if snapshotRequested then withMigrationSemantics True us core templates else id) $
           withAttestation attestation core obligations (withVerification verification (withPackages project described (programView settings us (map prettyExpanded es) files obligations (C.lowerProgramFields core)))) in case method of
          "check" -> result []
          "expand" -> result []
          "proofTasks" | Just selection <- verification ->
            if V.selected selection V.Proof
              then either failure (\tasks -> case result [] of
                Object response -> Object (KM.insert "proofTasks" (toJSON tasks) response)
                response -> response) (Smt.proofTasks core)
              else case result [] of
                Object response -> Object (KM.insert "proofTasks" (toJSON ([] :: [Smt.ProofTask])) response)
                response -> response
          "proofTasks" -> failure [Diagnostic "language-profile" "proofTasks requires API schema 5 and languageProfile 1.0-rc.1" Nothing]
          "format" | verification /= Nothing -> case preparePackagesWithReferences project packages (map formatSource sources) of
            Left ds -> failure ds
            Right (formatted,visible,referenceUnit,_) -> case compileCanonicalWithReferenceUnits referenceUnit visible bits settings formatted of
              Left ds -> failure ds
              Right _ -> withSources (map formatSource sources) (result [])
          "format" -> failure [Diagnostic "language-profile" "format requires API schema 5 and languageProfile 1.0-rc.1" Nothing]
          "planGeneration" -> either failure (withBenchmarks (benchmarkManifest target testDir core) . withTests (verificationKeys verification (testManifest target testDir (plannedCore core plan))) . result)
            ((++ networkArtifacts native) <$> (plan >>= emitPlanWithNativeOptions minify target sourceDir testDir bindings))
          _ -> failure [Diagnostic "request" ("unknown method: " ++ method) Nothing]

  where
    -- Where the compiler may keep work between runs; the CLI names one per
    -- project and compiler build.
    cacheDirectory = case decode bytes of
      Just (Object o) | Just (String d) <- KM.lookup "cacheDirectory" o -> Just (T.unpack d)
      _ -> Nothing
    snapshotRequested = case decode bytes of
      Just (Object o) -> KM.lookup "migrationSnapshot" o==Just (Bool True)
      _ -> False
    comparison Nothing = failure [Diagnostic "request" "migrationComparison requires migrated" Nothing]
    comparison (Just made) = case parseEither request made of
      Left reason -> failure [Diagnostic "request" ("migrated: " ++ reason) Nothing]
      Right (_,_,Left reason,_) -> failure [Diagnostic "attestation" ("migrated: " ++ reason) Nothing]
      Right ((_,afterSources,_,_,_,afterBits,afterSettings,_,afterNative,afterVerification),
          (afterProject,afterPackages),Right _,_) ->
        if maybe False (not . null . V.verificationLayers) afterVerification then
          failure [Diagnostic "request" "migrationComparison requires verification.layers [] on both inputs" Nothing]
        else case eitherDecode bytes >>= parseEither request of
          Right ((_,beforeSources,_,_,_,beforeBits,beforeSettings,_,beforeNative,beforeVerification),
              (beforeProject,beforePackages),Right _,_) ->
            if beforeBits/=afterBits then failure [Diagnostic "request" "migrationComparison requires matching machine widths" Nothing]
            else case memoized syntaxStagesTable ("comparison-before:" ++ sharedRequest bytes)
                (stagesWithInput False True beforeProject beforePackages beforeSources beforeBits beforeSettings beforeNative beforeVerification) of
              Left response -> comparisonFailure "before" response
              Right ((beforeUnits,_,beforeCore,_,_,_,_,beforeTemplates),_) ->
                case memoized syntaxStagesTable ("canonical:" ++ sharedRequest (encode made))
                    (stagesWithInput True True afterProject afterPackages afterSources afterBits afterSettings afterNative afterVerification) of
                  Left response -> comparisonFailure "migrated" response
                  Right ((afterUnits,_,afterCore,_,_,_,_,afterTemplates),_) ->
                    let result=case (beforeTemplates,afterTemplates) of
                          (Just previous,Just next) -> case payloadCorrespondenceWithPlan previous next of
                            Left reason -> unavailable reason
                            Right (view,Nothing) -> view
                            Right (Object fields,Just plan) ->
                              let names units=[(C.Id (unitName unit ++ "::law::" ++ lawName law),lawName law) | unit<-units,law<-laws unit]
                                  transported=either (\reason -> object ["status" .= ("not-established"::String),"reason" .= reason]) id
                                    (do (copy,view)<-transportComparisonWithProgram plan (names beforeUnits) beforeCore (names afterUnits) afterCore
                                        pure (withTransportDomains (names beforeUnits) copy (names afterUnits) afterCore view))
                              in Object (KM.insert "executableTransport" transported fields)
                            Right (view,_) -> view
                          _ -> unavailable "checked source templates were not captured for both inputs"
                    in withVerification (Just V.noVerification) (object ["diagnostics" .= ([]::[Diagnostic]),
                      "machineBits" .= beforeBits,"migrationComparison" .= result])
          _ -> failure [Diagnostic "request" "invalid migrationComparison input" Nothing]
    comparisonFailure side (Object fields) = Object (KM.insert "migrationComparisonInput" (String side) fields)
    comparisonFailure _ value = value
    unavailable reason = object ["status" .= ("unavailable"::String),"reason" .= (reason::String)]
    responseVersion = case eitherDecode bytes >>= parseEither
        (withObject "request" (\o -> o .:? "schemaVersion" .!= (3 :: Int))) of
      Right 5 -> 5 :: Int
      Right 4 -> 4 :: Int
      _ -> 3
    withPackages project described (Object value) =
      Object (foldr (\(k, v) -> KM.insert k v) value (packagesView project described))
    withPackages _ _ value = value
    versioned (Object value) = Object (KM.insert "schemaVersion" (toJSON responseVersion)
      (if responseVersion < 5 then legacyReferences value else value))
    versioned value = value
    -- Legacy grammars contain only unnamed external citations. Keep the old
    -- wire shape while schema 5 exposes checked documentary targets.
    legacyReferences value = case KM.lookup "laws" value of
      Just (Array laws) -> KM.insert "laws" (Array (fmap legacyLaw laws)) value
      _ -> value
    legacyLaw (Object law) = case KM.lookup "references" law of
      Just (Array refs) -> Object (KM.insert "references" (Array (fmap legacyCitation refs)) law)
      _ -> Object law
    legacyLaw value = value
    legacyCitation (Object reference) | Just resource <- KM.lookup "resource" reference = resource
    legacyCitation value = value
    request = withObject "request" $ \o -> do
      version <- o .:? "schemaVersion" .!= (3 :: Int)
      unless (version `elem` [3,4,5]) (fail "LawSpec requires API schemaVersion 3, 4 (migration) or 5; see docs/explanation/api-migration.md")
      snapshot <- o .:? "migrationSnapshot" .!= False
      unless (not snapshot || version==5) (fail "migrationSnapshot requires API schemaVersion 5 and languageProfile 1.0-rc.1")
      method <- o .:? "method" .!= "check"
      if method `elem` (["migrationBaseline","migrationComparison"] :: [String]) then do
        unless (version == 5) (fail (method ++ " requires API schemaVersion 5"))
        from <- o .: "from"
        unless (from == ("0.24" :: String)) (fail (method ++ " requires from 0.24"))
      else pure ()
      native <- o .:? "nativeBindings" .!= emptyNativeRequest
      unless (native == emptyNativeRequest || version `elem` [4,5])
        (fail "nativeBindings requires API schemaVersion 4; schema 3 compilers may ignore bindings")
      unless (null (requestNames native) || version == 5)
        (fail "native name overrides require API schemaVersion 5 and languageProfile 1.0-rc.1")
      verification <- if version == 5 then do
        profile <- o .: "languageProfile"
        unless (profile == ("1.0-rc.1" :: String)) (fail "schema 5 requires languageProfile 1.0-rc.1")
        Just <$> o .:? "verification" .!= V.noVerification
        else pure Nothing
      -- A project may itself be a package, and may depend on packages whose
      -- sources are supplied alongside its own.
      rootPackage <- o .:? "package" >>= traverse (withObject "package" (\p -> (,) <$> p .: "name" <*> p .: "version"))
      dependencies <- o .:? "dependencies" .!= mempty
      packages <- o .:? "packages" .!= []
      request' <- (,,,,,,,,,) <$> pure method <*> o .: "sources" <*> o .:? "target" .!= "" <*> o .:? "sourceDir" <*> o .:? "testDir" <*> o .:? "machineBits" .!= 64 <*> o .:? "generation" .!= defaultGeneration <*> o .:? "minify" .!= False <*> pure native <*> pure verification
      -- An environment attestation is reporting only: it annotates the
      -- evidence and never changes what is compiled or how a law is
      -- discharged. ref:DEC-environment-attestation
      attestation <- traverse parseAttestation <$> o .:? "attestation"
      migrated <- if method == "migrationComparison" then do
        unless (maybe True (null . V.verificationLayers) verification)
          (fail "migrationComparison requires verification.layers [] on both inputs")
        raw <- o .: "migrated"
        made <- withObject "migrated request" (\nested -> do
          nestedVersion <- nested .:? "schemaVersion" .!= (5::Int)
          unless (nestedVersion==5) (fail "migrated request requires API schemaVersion 5")
          pure (Object (KM.insert "schemaVersion" (toJSON (5::Int))
            (KM.insert "method" (String "check") nested)))) raw
        pure (Just made)
        else pure Nothing
      pure (request', (Project rootPackage dependencies, packages), attestation,migrated)

verificationKeys :: Maybe V.Verification -> [TestEntry] -> [TestEntry]
verificationKeys Nothing entries = entries
verificationKeys (Just config) entries = [entry { entryKey = digestHex (digestString (entryKey entry ++ show config)) } | entry <- entries]

plannedCore :: C.Program -> Either [Diagnostic] Plan -> C.Program
plannedCore core (Right plan) = core { C.programUnits = map plannedUnit (plannedUnits plan) }
plannedCore core _ = core

withSources :: [Source] -> Value -> Value
withSources sources (Object o) = Object (KM.insert "formattedSources" (toJSON sources) o)
withSources _ value = value

withMigrationSyntax :: [SourceSyntax] -> Value -> Value
withMigrationSyntax syntax (Object value) = Object
  (KM.insert "sourceLanguageProfile" (String "0.24") (KM.insert "sourceSyntax" (toJSON syntax) value))
withMigrationSyntax _ value = value

-- A comparison projection of the actual, fully admitted Core. Snapshot errors
-- never weaken mandatory validation or change which programs compile.
withMigrationSemantics :: Bool -> [Unit] -> C.Program -> Maybe SourceTemplates -> Value -> Value
withMigrationSemantics canonical units core templates (Object value) = Object
  (KM.insert "migrationSemantics" snapshot value)
  where
    names=[(C.Id (unitName unit ++ "::law::" ++ lawName law),lawName law) | unit<-units,law<-laws unit]
    snapshot=case Migration.migrationSnapshot canonical names core of
      Left reason -> object ["status" .= ("unavailable"::String),"reason" .= reason]
      Right (Object fields) -> Object (KM.insert "inputDomains" domainFields (KM.insert "sourceTemplates" templateFields (KM.insert "status" (String "available") fields)))
      Right _ -> object ["status" .= ("unavailable"::String),"reason" .= ("invalid Core snapshot"::String)]
    templateFields=case templates of
      Nothing -> object ["status" .= ("unavailable"::String),"reason" .= ("checked source templates were not captured"::String)]
      Just captured -> case templateSnapshot canonical captured of
        Left reason -> object ["status" .= ("unavailable"::String),"reason" .= reason]
        Right fields -> withTemplateInputDomains canonical captured core domainFields fields
    domainFields=case domainSnapshot canonical names core of
      Left reason -> object ["status" .= ("unavailable"::String),"reason" .= reason]
      Right fields -> fields
withMigrationSemantics _ _ _ _ value = value

-- Selected law checks are reported separately from completed evidence. This
-- field never claims that an unrun native test passed.
withVerification :: Maybe V.Verification -> Value -> Value
withVerification Nothing value = value
withVerification (Just config) (Object o) = Object (KM.insert "languageProfile" (String "1.0-rc.1")
  (KM.insert "verification" (object
    [ "layers" .= V.verificationLayers config
    , "selection" .= (if null (V.verificationLayers config) then "no-selected-checks" else "selected-checks" :: String)
    , "intrinsicDefinitionChecks" .= True ]) o))
withVerification _ value = value

-- | The evidence an environment attestation touches, with where its tests ran,
-- and the attestation itself as the report reads it.
withAttestation :: Maybe Attestation -> C.Program -> [Obligation] -> Value -> Value
withAttestation (Just attestation) core obligations (Object o) = Object
  $ KM.insert "attestation" (attestationView attestation core obligations)
  $ maybe o (\items -> KM.insert "evidence" items o) annotated
  where
    annotated = case KM.lookup "evidence" o of
      Just (Array items) -> Just (toJSON (zipWith annotate (toList items) (attestedFields attestation core obligations)))
      _ -> Nothing
    annotate (Object item) fields = Object (foldr (\(k, v) -> KM.insert k v) item fields)
    annotate item _ = item
withAttestation _ _ _ value = value

-- | Which generated tests check each law, for running a subset of them.
withTests :: [TestEntry] -> Value -> Value
withTests entries (Object o) = Object (KM.insert "tests" (toJSON (map entry entries)) o)
  where
    entry e = object
      [ "law" .= C.idText (entryLaw e), "unit" .= entryUnit e, "label" .= entryLabel e
      , "index" .= entryIndex e, "file" .= entryFile e, "key" .= entryKey e
      , "callsAdapters" .= entryCallsAdapters e, "name" .= entryName e, "tags" .= entryTags e
      , "skip" .= entrySkip e, "knownFailing" .= entryKnownFailing e
      , "parallel" .= entryParallel e ]
withTests _ value = value

-- The harness's benchmarks and the tests that measure them.
withBenchmarks :: [BenchmarkEntry] -> Value -> Value
withBenchmarks entries (Object o) = Object (KM.insert "benchmarks" (toJSON (map entry entries)) o)
  where
    entry e = object [ "unit" .= benchmarkUnit e, "benchmark" .= benchmarkName e, "file" .= benchmarkFile e, "name" .= benchmarkTest e ]
withBenchmarks _ value = value

failure :: [Diagnostic] -> Value
failure ds = object ["schemaVersion" .= (3 :: Int), "diagnostics" .= ds]

type Stages = ([Unit], [Expanded], C.Program, BindingPlan, [Obligation], [(Package, [String])], Either [Diagnostic] Plan,Maybe SourceTemplates)

stages :: Project -> [Package] -> [Source] -> Int -> Generation -> NativeRequest -> Maybe V.Verification -> Either Value Stages
stages project packages sources bits settings native verification =
  fst <$> stagesWithInput (verification /= Nothing) False project packages sources bits settings native verification

stagesWithInput :: Bool -> Bool -> Project -> [Package] -> [Source] -> Int -> Generation -> NativeRequest -> Maybe V.Verification -> Either Value (Stages,[SourceSyntax])
stagesWithInput canonical capture project packages sources bits settings native verification = case preparePackagesWithReferences project packages sources of
  Left ds -> Left (failure ds)
  Right (allSources,visible,referenceUnit,described) -> case
    (if capture then compileWithMigrationCapture canonical referenceUnit visible bits settings allSources
      else (\(units,properties) -> (units,properties,[],Nothing)) <$>
        (if canonical then compileCanonicalWithReferenceUnits referenceUnit visible else compileWithImports visible) bits settings allSources) of
    Left ds -> Left (failure (versionedDiagnostics described ds))
    Right (us,es,syntax,templates) -> case (if canonical then elaborateCanonical else elaborate) bits us es of
      Left ds -> Left (failure (versionedDiagnostics described ds))
      Right core -> case resolveNativeRequest core native of
        Left message -> Left (failure [Diagnostic "native-binding" message Nothing])
        Right bindings -> case maybe dischargeEvidence dischargeEvidenceWith verification core of
          Left ds -> Left (failure ds)
          Right evidence -> Right ((us, es, core, bindings, evidence, described, maybe planTesting planTestingWith verification core,templates),syntax)

-- | The request without the fields that only select a method, target or layout.
sharedRequest :: B.ByteString -> String
sharedRequest bytes = case decode bytes of
  Just (Object o) -> BC.unpack (encode (Object (foldr (KM.delete . K.fromString) o
    ["method", "target", "sourceDir", "testDir", "minify", "cacheDirectory", "attestation", "migrationSnapshot"])))
  _ -> BC.unpack bytes

-- | Two entries: each holds a whole compiled program and its plan.
stagesTable :: Table (Either Value Stages)
stagesTable = unsafePerformIO (newTable 2 (const 1))
{-# NOINLINE stagesTable #-}

-- Migration parses an explicitly selected legacy grammar. Its cache cannot
-- supply canonical check/format/generation responses, or vice versa.
syntaxStagesTable :: Table (Either Value (Stages,[SourceSyntax]))
syntaxStagesTable = unsafePerformIO (newTable 2 (const 1))
{-# NOINLINE syntaxStagesTable #-}
