-- | Which generated tests check each piece of evidence, for subset runs.
--
-- Every target writes one test file per unit, and names a law's tests after
-- its label (LawSpec.TestNames), or, in JavaScript and TypeScript, by the
-- label itself. The manifest gives each law its tests' name, its position,
-- its unit's test file, the law's result key (its semantic hash, from
-- LawSpec.Dependencies), and its harness: tags, and whether it is skipped or
-- known to fail. A runner can tell which laws an edit affects, select their
-- tests by name and by tag, and knows which tests not to expect. Selected
-- model, scenario and supervision checks on every target have distinct
-- evidence identities and dependency keys, even when a native method combines
-- several checks. The manifest records their actual files and native slots.
module LawSpec.TestManifest (TestEntry(..), testManifest, testManifestWithModelChecks, executableEntries, BenchmarkEntry(..), benchmarkManifest, unitTestPath) where
import LawSpec.Targets (artifactTargets)

import Data.Char (isAlphaNum, toUpper)
import Data.List (intercalate, stripPrefix, isSuffixOf)
import qualified Data.Set as S
import LawSpec.Core
import qualified LawSpec.Core.Machine as Machine
import qualified LawSpec.Core.Evidence as Evidence
import LawSpec.Dependencies (dependencyGraphWithBits, semanticKey, adapterKey)
import LawSpec.TestNames (unitTestNames, unitBenchmarkNames, lawWords)
import qualified LawSpec.BeamCode as Beam
import qualified LawSpec.BeamModelChecks as ModelChecks
import qualified LawSpec.DotNet.Names as DotNet
import qualified LawSpec.NativeModelChecks as NativeModels
import qualified LawSpec.Testing as Testing

-- | Each generated test is keyed by the law it checks and the digest of what the
-- law reaches, so lawspec test runs only the tests an edit can affect.
-- ref:DEC-incremental-compilation
data TestEntry = TestEntry
  { entryLaw :: Id, entryUnit :: String, entryLabel :: String, entryIndex :: Int
  , entryFile :: FilePath, entryKey :: String, entryCallsAdapters :: Bool
  -- The harness plane: the tests' base name, tags, skip and known failing.
  , entryName :: String, entryTags :: [String], entrySkip :: Maybe String
  , entryKnownFailing :: Maybe String
  -- Whether the law's unit lets its tests run at the same time (parallel).
  , entryParallel :: Bool
  -- Exact framework slots for model checks use no law-kind suffix.
  , entryKind :: Maybe String, entryScope :: Maybe String
  , entryObligations :: [(Id,String)] }
  deriving (Eq, Show)

-- | The manifest for one target, with its test directory if not the default.
testManifest :: String -> Maybe String -> Program -> [TestEntry]
testManifest=testManifestWithModelChecks True

-- | A complete empty input domain has no native test to run. Its existing Core
-- evidence remains authoritative; inventing a passed native case would erase
-- the distinction between domain proof and observed implementation execution.
-- Filter after naming so other laws retain their exact emitted slot names.
executableEntries :: Testing.Plan -> [TestEntry] -> [TestEntry]
executableEntries plan = filter ((`S.notMember` empty) . entryLaw)
  where
    empty=S.fromList [propertyId (Testing.plannedProperty property) |
      unit<-Testing.plannedUnits plan, property<-Testing.plannedProperties unit,
      Testing.finiteCases property==Just [], null (Testing.boundaryCases property),
      null (propertyExamples (Testing.plannedProperty property))]

testManifestWithModelChecks :: Bool -> String -> Maybe String -> Program -> [TestEntry]
testManifestWithModelChecks _ target _ _ | target `elem` artifactTargets = []
testManifestWithModelChecks modelsSelected "prolog" testDir program =
  [e {entryFile=prologPath (entryFile e)} | e <- testManifestWithModelChecks modelsSelected "python" testDir program]
testManifestWithModelChecks modelsSelected target testDir program =
  [ TestEntry (propertyId p) unit (unit ++ "::" ++ propertyName p) index
      (relocated (unitTestPath target unit)) (lawKey u p)
      (callsAdapters p)
      testName (harnessTags (propertyHarness p)) (harnessSkip (propertyHarness p)) (harnessKnownFailing (propertyHarness p))
      (maybe False harnessParallel (unitHarnessSettings u)) Nothing Nothing []
  | u <- programUnits program
  , let unit = idText (unitId u)
        names = if target `elem` ["javascript", "typescript"] then [unit ++ "::" ++ propertyName p | p <- unitProperties u]
          else unitTestNames target (map propertyName (unitProperties u))
  , (index, p, testName) <- zip3 [0 ..] (unitProperties u) names ] ++
  [ TestEntry (ModelChecks.checkIdentity check) unit (ModelChecks.checkLabel check) index
      (relocated (unitTestPath target unit))
      (modelKey u check)
      (ModelChecks.checkAction check /= ModelChecks.Supervision)
      (ModelChecks.checkName check) [] Nothing Nothing
      (maybe False harnessParallel (unitHarnessSettings u)) Nothing Nothing (obligations u check)
  | modelsSelected, target `elem` ["erlang", "elixir", "gleam"], u <- programUnits program
  , let unit = idText (unitId u)
  , (index, check) <- zip [length (unitProperties u) ..] (ModelChecks.checks u) ] ++
  -- .NET writes a unit's model, scenario and supervision checks to a test
  -- file of their own, named after the check (PascalCase in C#).
  [ TestEntry (ModelChecks.checkIdentity check) unit (ModelChecks.checkLabel check) index
      (relocated (dotnetModelsPath target unit))
      (modelKey u check)
      (ModelChecks.checkAction check /= ModelChecks.Supervision)
      (if target == "csharp" then pascalCase (ModelChecks.checkName check) else ModelChecks.checkName check) [] Nothing Nothing
      (maybe False harnessParallel (unitHarnessSettings u)) Nothing Nothing (obligations u check)
  | modelsSelected, target `elem` ["fsharp", "csharp", "swift"], u <- programUnits program
  , not (null (unitMachines u) && null (unitSupervisors u))
  , let unit = idText (unitId u)
  , (index, check) <- zip [length (unitProperties u) ..] (ModelChecks.checks u) ] ++
  [ TestEntry (ModelChecks.checkIdentity check) unit (ModelChecks.checkLabel check) index
      (relocated (NativeModels.checkFile native))
      (modelKey u check)
      (ModelChecks.checkAction check/=ModelChecks.Supervision)
      (NativeModels.checkTestName native) [] Nothing Nothing
      (maybe False harnessParallel (unitHarnessSettings u)) (Just "model") (NativeModels.checkScope native) (obligations u check)
  | modelsSelected,u<-programUnits program,let unit=idText (unitId u)
  , (index,native)<-zip [length (unitProperties u)..] (NativeModels.nativeChecks target (unitTestPath target unit) u)
  , let check=NativeModels.checkEvidence native ]
  where
    -- A test's result depends on what the law does, never on how it is
    -- written: its key is the law's semantic hash, the machine width and the
    -- unit's harness settings, not the generated file. A law that runs
    -- native code keeps its public interface names, not checked locals.
    -- ref:DEC-content-identity
    lawKey u p = if callsAdapters p
      then adapterKey graph (show (programMachineBits program)) (p, unitHarnessSettings u)
      else semanticKey graph (show (programMachineBits program)) (p, unitHarnessSettings u)
    callsAdapters p = any (`S.notMember` definitions) (concatMap callees (propertyExpressions p)) ||
        -- A native production handler is native code too.
        any (native . snd) [h | h@(a, _) <- propertyHandlers p, not (isFail a)]
    -- Model, scenario and supervision checks run the unit's machines against
    -- native code.
    modelKey u check = adapterKey graph (show (programMachineBits program, actionKind (ModelChecks.checkAction check)))
      (selectedModels (ModelChecks.checkAction check),
        concatMap unitSessions (programUnits program),
        (unitMailboxes u, unitSupervisors u), unitHarnessSettings u)
    selectedModels action = case action of
      ModelChecks.Sequential _ machine -> [machine { Machine.machineScenarios = [] }]
      ModelChecks.Parallel _ machine -> [machine { Machine.machineScenarios = [] }]
      ModelChecks.Scenario _ machine program -> [machine { Machine.machineScenarios = [program] }]
      ModelChecks.Supervision -> []
    actionKind action = case action of
      ModelChecks.Sequential _ _ -> "sequential"
      ModelChecks.Parallel _ _ -> "parallel"
      ModelChecks.Scenario _ _ _ -> "scenario"
      ModelChecks.Supervision -> "supervision"
    obligations unit check=[(Evidence.obligationDeclaration item,Evidence.obligationStage item) |
      item<-ModelChecks.checkObligations unit check]
    graph = dependencyGraphWithBits (programMachineBits program) (programDataDeclarations program) (programUnits program)
    native h = case h of
      ProductionHandler -> True
      RecordingHandler inner -> native inner
      SpecHandler _ -> False
    definitions = S.fromList [declarationId (definitionDeclaration d) | u <- programUnits program, d <- unitDefinitions u]
    -- A custom test directory replaces the default one, as the emitters' layout does.
    relocated path = case testDir of
      Just directory | Just rest <- stripPrefix (defaultTestDirectory target ++ "/") path -> directory ++ "/" ++ rest
      _ -> path

-- A harness benchmark and the test that measures it, which lawspec test
-- --benchmarks runs.
data BenchmarkEntry = BenchmarkEntry
  { benchmarkUnit :: String, benchmarkName :: String, benchmarkFile :: FilePath, benchmarkTest :: String }
  deriving (Eq, Show)

benchmarkManifest :: String -> Maybe String -> Program -> [BenchmarkEntry]
benchmarkManifest target _ _ | target `elem` artifactTargets = []
benchmarkManifest "prolog" testDir program =
  [e {benchmarkFile=prologPath (benchmarkFile e)} | e <- benchmarkManifest "python" testDir program]
benchmarkManifest target testDir program =
  [ BenchmarkEntry unit n (relocated testDir target (unitTestPath target unit)) (testOf n nativeName)
  | u <- programUnits program, Just settings <- [unitHarnessSettings u]
  , let unit = idText (unitId u)
  , ((n, _), nativeName) <- zip (harnessBenchmarks settings) (unitBenchmarkNames (map fst (harnessBenchmarks settings))) ]
  where
    words' = lawWords
    capital (c : rest) = toUpper c : rest
    capital [] = []
    testOf n nativeName = case target of
      "python" -> "test_benchmark__" ++ intercalate "_" (words' n)
      "go" -> "TestBenchmark" ++ concatMap capital (words' n)
      "java" -> "benchmark" ++ concatMap capital (words' n)
      "rust" -> "benchmark_" ++ intercalate "_" (words' n)
      "erlang" -> nativeName
      "elixir" -> nativeName
      "gleam" -> nativeName
      "fsharp" -> DotNet.camel nativeName
      "csharp" -> DotNet.pascal nativeName
      "groovy" -> "benchmark: " ++ unwords (words' n)
      "clojure" -> "benchmark--" ++ intercalate "-" (words' n)
      "swift" -> DotNet.camel nativeName
      _ -> "benchmark " ++ n

relocated :: Maybe String -> String -> FilePath -> FilePath
relocated testDir target path = case testDir of
  Just directory | Just rest <- stripPrefix (defaultTestDirectory target ++ "/") path -> directory ++ "/" ++ rest
  _ -> path

defaultTestDirectory :: String -> String
defaultTestDirectory target = case target of
  "prolog" -> "tests"
  "fsharp" -> "tests"
  "csharp" -> "tests"
  "swift" -> "tests"
  "java" -> "src/test/java"
  "kotlin" -> "src/test/kotlin"
  "scala" -> "src/test/scala"
  "groovy" -> "src/test/groovy"
  "python" -> "tests"
  "rust" -> "tests"
  "go" -> ""
  _ -> "test"

-- | The test file each target generates for a unit, in the default layout.
unitTestPath :: String -> String -> FilePath
unitTestPath target unit = case target of
  "prolog" -> prologPath (unitTestPath "python" unit)
  "python" -> "tests/test_" ++ intercalate "_" parts ++ "_lawspec.py"
  "javascript" -> "test/" ++ intercalate "_" parts ++ ".lawspec.test.mjs"
  "typescript" -> "test/" ++ intercalate "_" parts ++ ".lawspec.test.ts"
  "go" -> intercalate "/" parts ++ "/lawspec_test.go"
  "haskell" -> "test/" ++ intercalate "/" (map capitalWords parts) ++ "Spec.hs"
  "rust" -> "tests/" ++ map (\c -> if isAlphaNum c || c == '_' then c else '_') unit ++ "_lawspec.rs"
  "erlang" -> "test/" ++ Beam.moduleName (Id unit) ++ "_lawspec_tests.erl"
  "elixir" -> "test/" ++ Beam.moduleName (Id unit) ++ "_lawspec_test.exs"
  "gleam" -> "test/" ++ Beam.moduleName (Id unit) ++ "_lawspec_test.gleam"
  "fsharp" -> "tests/LawSpec/" ++ dotnetName unit ++ ".fs"
  "csharp" -> "tests/LawSpec/" ++ dotnetName unit ++ ".cs"
  -- A clojure.test namespace (LawSpec.Clojure.Emit).
  "clojure" -> "test/" ++ intercalate "/" parts ++ "_lawspec_test.clj"
  -- A Spock specification (LawSpec.Groovy.Emit).
  "groovy" -> "src/test/groovy/" ++ intercalate "/" (init parts ++ [capitalWords (last parts)]) ++ "LawSpec.groovy"
  "swift" -> "tests/LawSpec/" ++ dotnetName unit ++ ".swift"
  jvm -> "src/test/" ++ jvm ++ "/" ++ intercalate "/" (init parts ++ [capitalWords (last parts)]) ++ "LawSpecTest" ++
    (if jvm == "kotlin" then ".kt" else if jvm == "scala" then ".scala" else ".java")
  where
    parts = splitOn '.' unit
    capitalWords = concatMap capital . splitOn '_'
    capital (c : rest) = toUpper c : rest
    capital [] = []
    splitOn c s = case break (== c) s of
      (a, []) -> [a]
      (a, _ : b) -> a : splitOn c b

-- | A unit's .NET test class: each dotted part in PascalCase.
dotnetName :: String -> String
dotnetName = concatMap DotNet.pascal . DotNet.splitDots

pascalCase :: String -> String
pascalCase = DotNet.pascal

-- | The test file of a unit's .NET model checks.
dotnetModelsPath :: String -> String -> FilePath
dotnetModelsPath target unit = "tests/LawSpec/" ++ dotnetName unit ++ "Models" ++ (case target of
  "csharp" -> ".cs"
  "swift" -> ".swift"
  _ -> ".fs")

-- | The declarations a law calls directly; definitions cannot call adapters.
callees :: Expr -> [Id]
callees e = case expressionNode e of
  ExternalCall callee args -> callee : concatMap callees args
  _ -> concatMap callees (children e)

prologPath :: FilePath -> FilePath
prologPath path = if ".py" `isSuffixOf` path then take (length path-3) path ++ ".pl" else path
