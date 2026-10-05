module LawSpec.CoreEmit (emitPlan, emitPlanWithFormat, emitPlanWithLayout, emitPlanWithOptions, emitPlanWithNativeOptions, targets) where
import LawSpec.Sessions (sessionArtifacts)
import LawSpec.Actors (actorArtifacts)
import LawSpec.MachineSpec (scenarioWire)
import LawSpec.Remote (remoteArtifacts)
import LawSpec.Core.Machine (Machine(..))
import LawSpec.Core.Program (Program(..))
import LawSpec.Backend
import LawSpec.Common
import LawSpec.Testing
import LawSpec.Witness (witnessPlan)
import LawSpec.Collections (isCollectionsType)
import LawSpec.RustEmit (emitRustWithFormat, emitRustWithBindings)
import qualified LawSpec.NativeBinding as Binding
import qualified LawSpec.NativeRequest as NB
import qualified LawSpec.CoreScalarEmit as Scalar
import qualified LawSpec.CoreNativeScalarEmit as Native
import qualified LawSpec.JavaData as JavaData
import qualified LawSpec.JavaNativeBinding as JavaNativeBinding
import qualified LawSpec.KotlinNativeBinding as KotlinNativeBinding
import qualified LawSpec.GoNativeBinding as GoNativeBinding
import qualified LawSpec.JavaDefinitions as JavaDefinitions
import qualified LawSpec.HaskellNativeBinding as HaskellNativeBinding
import qualified LawSpec.HaskellData as HaskellData
import qualified LawSpec.HaskellDefinitions as HaskellDefinitions
import qualified LawSpec.KotlinData as KotlinData
import qualified LawSpec.KotlinDefinitions as KotlinDefinitions
import qualified LawSpec.GoDefinitions as GoDefinitions
import qualified LawSpec.PythonData as PythonData
import qualified LawSpec.PythonNativeBinding as PythonNativeBinding
import qualified LawSpec.PythonDefinitions as PythonDefinitions
import qualified LawSpec.RustDefinitions as RustDefinitions
import qualified LawSpec.WebData as WebData
import qualified LawSpec.WebNativeBinding as WebNativeBinding
import qualified LawSpec.WebDefinitions as WebDefinitions
import qualified LawSpec.Code.Doc as Doc
import LawSpec.RuntimeSources
import qualified LawSpec.Core as C
import LawSpec.Scalar (primitive)
import LawSpec.TargetNames (nativeName, allTargetKeywords)
import Data.Char (toUpper, toLower, isAscii, isAlphaNum)
import Data.List (intercalate, nub, stripPrefix, isPrefixOf, isSuffixOf)
import Control.Monad (unless)
import LawSpec.Memo (Table, newPersistentTable, memoized)
import Data.Binary (Binary(..))
import qualified Data.Text as T
import qualified LawSpec.Dependencies as D
import LawSpec.Digest (digestHex, digestString)
import System.IO.Unsafe (unsafePerformIO)

targets :: [String]
targets = ["java","python","javascript","typescript","go","haskell","kotlin","rust"]
split :: Char -> String -> [String]
split c s = case break (==c) s of (a,[]) -> [a]; (a,_:b) -> a:split c b
cap :: String -> String
cap [] = []
cap (a:b) = toUpper a:b
comma :: [String] -> String
comma = intercalate ", "

reserved :: [String]
reserved = words "class interface enum public private protected static return import package module where data type newtype case of if then else let in do forall object fun val var when is as null true false None True False def lambda pass raise from with yield async await export default function const new delete switch throw try catch finally break continue for while match typealias struct func map range select defer go chan int string error assert test"

-- Preserve the readable default for existing compiler callers.
emitPlan :: String -> Plan -> Either [Diagnostic] [Artifact]
emitPlan = emitPlanWithFormat False

-- Canonical adapter references are independent of the selected presentation.
-- Legacy runtime/test templates are still being migrated to structured Docs.
emitPlanWithFormat :: Bool -> String -> Plan -> Either [Diagnostic] [Artifact]
emitPlanWithFormat minify target original = do
  let plan = wirePlan (escapePlan target (witnessPlan original))
  emittedFiles <- emitPlanFormatted minify target plan
  -- Typed channel ends for the unit's protocols, for implementation code.
  sessions <- sessionArtifacts minify target plan
  -- Typed actors, for implementation code.
  actors <- actorArtifacts minify target plan
  -- Definitions other nodes can evaluate, by content hash.
  let remote = remoteArtifacts target (remoteCalls target plan) plan
      files = emittedFiles ++ sessions ++ actors ++ remote
  canonical <- if minify then emitPlanFormatted False target plan else pure files
  let references = [(artifactPath a, artifactContent a) | a <- canonical, ownership a == "user"]
  mapM (\artifact -> if ownership artifact /= "user" then pure artifact else
    case lookup (artifactPath artifact) references of
      Nothing -> Left [Diagnostic "target" "formatted adapter has no canonical reference" Nothing]
      Just reference -> pure (AdapterArtifact (artifactPath artifact) (artifactContent artifact)
        (ownership artifact) (artifactPlacement artifact) reference)) files

-- Each scenario's channel types, for its runs over a network. A scenario
-- whose types have no wire descriptor yet runs only in memory.
wirePlan :: Plan -> Plan
wirePlan plan = plan { plannedUnits = [u { plannedUnit = wired (plannedUnit u) } | u <- plannedUnits plan] }
  where
    wired unit = unit { C.unitMachines = [m { machineScenarios = map (program unit) (machineScenarios m) } | m <- C.unitMachines unit] }
    program unit p = p { programWire = either (const "") id
      (scenarioWire (planMachineBits plan) (planDataDeclarations plan) (C.unitSessions unit) p) }

-- A declaration named with a keyword of the target is emitted with a leading
-- underscore (LawSpec.TargetNames). Escaping is idempotent, and identities are
-- unchanged, so calls, contracts and bindings still resolve.
escapePlan :: String -> Plan -> Plan
escapePlan target plan = plan { plannedUnits = [u { plannedUnit = escapeUnit (plannedUnit u) } | u <- plannedUnits plan] }
  where
    escapeUnit unit = unit
      { C.unitDeclarations = map (escapeDeclaration target) (C.unitDeclarations unit)
      , C.unitDefinitions = [d { C.definitionDeclaration = escapeDeclaration target (C.definitionDeclaration d) }
                            | d <- C.unitDefinitions unit] }

escapeDeclaration :: String -> C.Declaration -> C.Declaration
escapeDeclaration target d = d { C.declarationName = nativeName target (C.declarationName d) }

escapeBindings :: String -> NB.BindingPlan -> NB.BindingPlan
escapeBindings target b = b { NB.bindingFunctions = [(escapeDeclaration target d, r) | (d, r) <- NB.bindingFunctions b]
                             , NB.bindingCalls = [(escapeDeclaration target d, c) | (d, c) <- NB.bindingCalls b] }

emitPlanFormatted :: Bool -> String -> Plan -> Either [Diagnostic] [Artifact]
emitPlanFormatted _ target plan
  | target `notElem` ["python","javascript","typescript","rust","java","kotlin","go","haskell"], any (not . null . C.constructorPredicates) (concatMap C.dataConstructors (planDataDeclarations plan)) =
      Left [Diagnostic "target" "constructor field contracts require native runtime enforcement" Nothing]
emitPlanFormatted _ target plan | target /= "rust", any containsMatch expressions =
  Left [Diagnostic "target" ("no match expression emitter for " ++ target) Nothing]
  where
    expressions = concat
      [concatMap C.contractExpressions (C.unitContracts (plannedUnit u)) ++
       concatMap (C.propertyExpressions . plannedProperty) (plannedProperties u) | u <- plannedUnits plan]
    containsMatch expression = case C.expressionNode expression of
      C.Match scrutinee branches ->
        not (supportedMatch (C.expressionType scrutinee))
          || any containsMatch (scrutinee : map C.caseBody branches)
      _ -> any containsMatch (C.children expression)
    supportedMatch (C.Constructor name _) =
      target `elem` ["java","python","javascript","typescript","go","haskell","kotlin"] && any ((== C.Id name) . C.dataId) (planDataDeclarations plan) ||
      target `elem` ["python","javascript","typescript","haskell","java","kotlin","go"] && name `elem` ["List","Maybe","Either"] ||
      target `elem` ["go"] && name == "List"
    supportedMatch _ = False
emitPlanFormatted _ target plan | target /= "rust", any containsConstruction expressions =
  Left [Diagnostic "target" ("no constructor expression emitter for " ++ target) Nothing]
  where
    expressions = concat
      [concatMap C.contractExpressions (C.unitContracts (plannedUnit u)) ++
       concatMap (C.propertyExpressions . plannedProperty) (plannedProperties u) | u <- plannedUnits plan]
    containsConstruction expression = case C.expressionNode expression of
      C.Construct tag fields -> not
        (target `elem` ["java","python","javascript","typescript","go","haskell","kotlin"] && any ((== tag) . C.constructorId) (concatMap C.dataConstructors (planDataDeclarations plan)) ||
         target `elem` ["python","javascript","typescript","haskell","java","kotlin","go"] &&
         C.idText tag `elem` ["List::Nil","List::Cons","Maybe::Nothing","Maybe::Just","Either::Left","Either::Right"] ||
         target `elem` ["go"] && C.idText tag `elem` ["List::Nil","List::Cons"]) || any containsConstruction fields
      _ -> any containsConstruction (C.children expression)
emitPlanFormatted _ target Plan{planDataDeclarations=(_: _)} | target `notElem` ["rust", "java", "python", "javascript", "typescript", "go", "haskell", "kotlin"] =
  Left [Diagnostic "target" ("no data declaration emitter for " ++ target) Nothing]
emitPlanFormatted _ target plan | target /= "rust", any (not . supportedRepresentationWithData target (planDataDeclarations plan) . C.declarationType)
  [d | u <- plannedUnits plan, d <- C.unitDeclarations (plannedUnit u)] =
    Left [Diagnostic "target" ("no structural adapter emitter for " ++ target) Nothing]
emitPlanFormatted minify "rust" plan = emitRustWithFormat minify plan
emitPlanFormatted minify target Plan{..} = do
  unless (target `elem` targets) (Left [Diagnostic "target" ("unknown target: " ++ target) Nothing])
  let units = map plannedUnit plannedUnits
      laws = concatMap plannedProperties plannedUnits
      aliases = [alias | target `elem` ["python","javascript","typescript"], alias <- ["ls","data","schema","_schema","_builtins","_definitions","_lawspec_schema"]] ++
        [alias | target `elem` ["javascript","typescript"], alias <- ["globalThis","eval","arguments"]]
      invalid n = not (all (\c -> isAscii c && (isAlphaNum c || c == '_')) n)
      -- A function named with a target keyword is escaped (escapePlan); other
      -- reserved words, and every reserved word in a module path, are rejected.
      bad = [n | u <- units, n <- map fst (functions u), n `elem` (filter (`notElem` allTargetKeywords) reserved ++ aliases) || invalid n] ++
        [n | u <- units, n <- split '.' (unitName u), n `elem` (reserved ++ aliases) || invalid n]
  unless (null bad) (Left [Diagnostic "identifier" ("reserved target identifier: " ++ comma bad) Nothing])
  let kotlinRuntimeNames = map ("lawspec.runtime." ++)
        ["LawSpecRuntime", "LawSpecSchema", "LawSpecDataSchema", "LawSpecDataCodecs",
         "LawSpecKotlin", "LawSpecKotlinCodecs", "LawSpecDefinitionBodies"]
      jvmName u = let pieces = split '.' (unitName u)
        in intercalate "." (init pieces ++ [concatMap cap (split '_' (last pieces))])
  unless (target /= "kotlin" || all (\u -> jvmName u `notElem` kotlinRuntimeNames) units)
    (Left [Diagnostic "collision" "Kotlin adapter shadows a generated JVM runtime class" Nothing])
  unless (target /= "kotlin" || all ((/= "kotlin") . head . split '.' . unitName) units)
    (Left [Diagnostic "identifier" "Kotlin's kotlin package is reserved" Nothing])
  emitted <- mapM (emitUnit laws) (filter (\u -> not (null (functions u)) || any ((== unitName u) . owner) laws) units)
  dataFiles <- if target == "java" && (not (null planDataDeclarations) || not (null definitionCalls) || hasPayload)
    then either (Left . pure . (\m -> Diagnostic "target" m Nothing)) Right
      (JavaData.emitJavaDataWithProfile planMachineBits (layout (Doc.Pretty 100)) planDataDeclarations)
    else if target == "python" && portableSchemaNeeded
      then either (Left . pure . (\m -> Diagnostic "target" m Nothing)) Right
        (PythonData.emitPythonDataWithProfile planMachineBits (layout (Doc.Pretty 79)) planDataDeclarations)
      else if target `elem` ["javascript","typescript"] && portableSchemaNeeded
        then either (Left . pure . (\m -> Diagnostic "target" m Nothing)) Right
          (WebData.emitWebDataWithProfile (target == "typescript") planMachineBits (layout (Doc.Pretty 80)) planDataDeclarations)
        else if target == "haskell" then do
          let emitted = [("LawSpecData.hs", HaskellData.emitHaskellData),
                ("LawSpecDataSchema.hs", HaskellData.emitHaskellSchemaWithProfile planMachineBits),
                ("LawSpecDataCodecs.hs", HaskellData.emitHaskellCodecs)]
          files <- mapM (\(filename,emit) -> do
            content <- either (Left . pure . (\m -> Diagnostic "target" m Nothing)) Right
              (emit (layout (Doc.Pretty 80)) planDataDeclarations)
            pure (Artifact ("src/" ++ filename) content "generated" "source")) emitted
          -- Collection codecs need the containers package, so only programs
          -- that use collections get them.
          let usesCollections = any (isCollectionsType . C.idText . C.dataId) planDataDeclarations
          pure (files ++ [Artifact (directory ++ filename) (runtimeSource source) "generated" placement |
            (directory,filename,source,placement) <-
              [("src/","LawSpecSchema.hs","haskell-schema","source"),
               ("src/","LawSpecCodecs.hs","haskell-codecs","source")] ++
              [("src/","LawSpecCollectionCodecs.hs","haskell-collection-codecs","source") | usesCollections] ++
              [("test/","LawSpecDataStrategies.hs","haskell-data-strategies","test")]])
        else if target == "kotlin" then
          either (Left . pure . (\m -> Diagnostic "target" m Nothing)) Right
            (KotlinData.emitKotlinDataWithProfile planMachineBits (layout (Doc.Pretty 100)) planDataDeclarations)
        else Right []
  definitionFiles <- if target == "java"
    then either (Left . pure . (\m -> Diagnostic "target" m Nothing)) Right
      (JavaDefinitions.emitJavaDefinitions (layout (Doc.Pretty 100)) planMachineBits planDataDeclarations units)
    else if target == "kotlin"
      then either (Left . pure . (\m -> Diagnostic "target" m Nothing)) Right
        (KotlinDefinitions.emitKotlinDefinitions (layout (Doc.Pretty 100)) planMachineBits planDataDeclarations units)
      else if target == "python"
        then either (Left . pure . (\m -> Diagnostic "target" m Nothing)) Right
          (PythonDefinitions.emitPythonDefinitions (layout (Doc.Pretty 79)) planMachineBits planDataDeclarations units)
        else if target `elem` ["javascript","typescript"]
          then either (Left . pure . (\m -> Diagnostic "target" m Nothing)) Right
            (WebDefinitions.emitWebDefinitions (target == "typescript") (layout (Doc.Pretty 80)) planMachineBits planDataDeclarations units)
          else if target == "go"
            then either (Left . pure . (\m -> Diagnostic "target" m Nothing)) Right
              (GoDefinitions.emitGoDefinitions (layout (Doc.PrettyTabs 100)) planMachineBits planDataDeclarations
                (filter (\u -> not (null (functions u)) || any ((== unitName u) . owner) laws) units))
            else if target == "haskell"
              then either (Left . pure . (\m -> Diagnostic "target" m Nothing)) Right
                (HaskellDefinitions.emitHaskellDefinitions (layout (Doc.Pretty 80)) planMachineBits planDataDeclarations units)
              else pure []
  let needsRuntime = not (null emitted) || not (null dataFiles)
      runtime = case target of
        "python" -> Artifact "src/lawspec_runtime.py" (runtimeSource "python") "generated" "source"
        "java" -> Artifact "src/main/java/lawspec/runtime/LawSpecRuntime.java" (runtimeSource "java") "generated" "source"
        "kotlin" -> Artifact "src/main/java/lawspec/runtime/LawSpecRuntime.java" (runtimeSource "java") "generated" "source"
        "typescript" -> Artifact "src/lawspec_runtime.ts" ("// @ts-nocheck\n" ++ runtimeSource "javascript") "generated" "source"
        "haskell" -> Artifact "src/LawSpecRuntime.hs" (runtimeSource "haskell") "generated" "source"
        _ -> Artifact "src/lawspec_runtime.mjs" (runtimeSource "javascript") "generated" "source"
      files = concat emitted ++ dataFiles ++ definitionFiles ++
        [Artifact "src/test/java/lawspec/testing/LawSpecDataStrategies.java" (runtimeSource "java-data-strategies") "generated" "test" | target == "java" && not (null dataFiles)] ++
        [Artifact "tests/lawspec_data_strategies.py" (runtimeSource "python-data-strategies") "generated" "test" | target == "python" && not (null dataFiles)] ++
        [Artifact ("test/lawspec_data_strategies." ++ if target == "typescript" then "ts" else "mjs")
          ((if target == "typescript" then "// @ts-nocheck\n" else "") ++ webStrategies) "generated" "test" | target `elem` ["javascript","typescript"] && not (null dataFiles)] ++ [runtime | needsRuntime && target /= "go"] ++
        [Artifact "src/test/kotlin/lawspec/testing/LawSpecKotlinStrategies.kt" (runtimeSource "kotlin-data-strategies") "generated" "test" | needsRuntime && target == "kotlin"] ++
        [Artifact "src/test/kotlin/lawspec/testing/LawSpecStrategies.kt" (runtimeSource "kotlin-strategies") "generated" "test" | needsRuntime && target == "kotlin"]
  unless (target `notElem` ["python","javascript","typescript"] || all
    (\u -> map toLower (head (split '.' (unitName u))) `notElem`
      ["lawspec_runtime","lawspec_schema","lawspec_data","lawspec_data_strategies","lawspec_definitions","lawspec_definition_bodies"]) units)
    (Left [Diagnostic "collision" ("unit shadows a generated " ++ target ++ " support module") Nothing])
  unless (target /= "python" || not (or
    [(map toLower (unitName a) ++ ".") `isPrefixOf` map toLower (unitName b) | a <- units, b <- units]))
    (Left [Diagnostic "collision" "a Python unit module shadows another unit's package" Nothing])
  unless (length files == length (nub (map (map toLower . artifactPath) files))) (Left [Diagnostic "collision" "units map to the same output path" Nothing])
  let generatedNames u = map (\(n,_) -> if target == "go" then cap n else n) (functions u)
  unless (all (\u -> let ns = generatedNames u in length ns == length (nub ns)) units) (Left [Diagnostic "collision" "functions map to the same target identifier" Nothing])
  pure files
  where
    layout = Doc.selectLayout minify
    definitionCalls = JavaDefinitions.definitionCalls (map plannedUnit plannedUnits)
    webStrategies = unlines [if line == "import * as ls from './lawspec_runtime.mjs';"
      then "import * as ls from '../src/lawspec_runtime." ++ (if target == "typescript" then "js" else "mjs") ++ "';"
      else if line == schemaImport
      then "import {RefinementViolation, witnessed, witnessInstances} from '../src/lawspec_schema." ++ (if target == "typescript" then "js" else "mjs") ++ "';"
      else line | line <- lines (runtimeSource "web-data-strategies")]
    requiresSchema = if target == "python" then PythonData.requiresSchema else WebData.requiresSchema
    hasPayload = any payloadExpression
      (concatMap (concatMap C.contractExpressions . contracts . plannedUnit) plannedUnits ++
       concatMap (C.propertyExpressions . original) (concatMap plannedProperties plannedUnits))
    payloadExpression term = case C.expressionNode term of
      C.AllPayloads _ _ -> True
      _ -> any payloadExpression (C.children term)
    portableSchemaNeeded = not (null definitionCalls) || not (null planDataDeclarations) ||
      any (requiresSchema planDataDeclarations . snd)
        (concatMap (functions . plannedUnit) plannedUnits) ||
      any (any (requiresSchema planDataDeclarations . inputType) . inputs)
        (concatMap plannedProperties plannedUnits) ||
      any expressionNeedsSchema
        (concatMap (concatMap C.contractExpressions . contracts . plannedUnit) plannedUnits ++
         concatMap (C.propertyExpressions . original) (concatMap plannedProperties plannedUnits))
    expressionNeedsSchema term | C.AllPayloads _ _ <- C.expressionNode term = True
    expressionNeedsSchema term = requiresSchema planDataDeclarations (C.expressionType term) ||
      any expressionNeedsSchema (C.children term)
    -- A unit's files are a function of exactly these inputs, so its key is
    -- their content: the unit, its laws (each by its plan key, which covers
    -- the law and everything it reaches), Java's data budget (sized across
    -- every law on purpose), every data declaration (emitters disambiguate
    -- type names across the program) and the table naming each checked
    -- definition. Editing a definition's body elsewhere re-emits only the
    -- units whose laws reach it.
    graph = D.dependencyGraph planDataDeclarations (map plannedUnit plannedUnits)
    dataDigest = digestHex (digestString (show planDataDeclarations))
    calls
      | target `elem` ["java","kotlin"] = definitionCalls
      | target == "go" = GoDefinitions.definitionCalls (map plannedUnit plannedUnits)
      | target == "haskell" = HaskellDefinitions.definitionCalls (map plannedUnit plannedUnits)
      | target == "python" = PythonDefinitions.definitionCalls (map plannedUnit plannedUnits)
      | otherwise = WebDefinitions.definitionCalls (map plannedUnit plannedUnits)
    lawKey law = D.keyOf graph (show (planMachineBits, plannedProperty law)) (D.lawReferences graph (plannedProperty law))
    emitUnit laws u =
      let owned = filter ((== unitName u) . owner) laws
      in fmap (map unstore) $ memoized emitTable (digestHex (digestString (show (minify, target, planMachineBits,
             u { C.unitProperties = [] }, map lawKey owned, Native.dataBudget laws, dataDigest, calls))))
           (fmap (map store) (emitUnitWith laws u))
    emitUnitWith laws u
      | target `elem` ["java","kotlin","go","haskell"] =
          Native.nativeScalarEmitWithFormat minify planDataDeclarations calls planMachineBits target u laws
      | otherwise = Scalar.scalarEmitWithFormat minify planDataDeclarations calls planMachineBits target u laws

supportedRepresentationWithData :: String -> [C.DataDeclaration] -> C.Type -> Bool
supportedRepresentationWithData target declarations ty = case ty of
  C.Constructor name args | target `elem` ["java","python","javascript","typescript","go","haskell","kotlin"], any ((== C.Id name) . C.dataId) declarations ->
    all (\arg -> case arg of C.TypeArgument t -> supportedRepresentationWithData target declarations t; _ -> False) args
  C.Constructor name args | name `elem` ["List", "Maybe", "Either", "Nullable", "Optional"] ->
    all (\arg -> case arg of C.TypeArgument t -> supportedRepresentationWithData target declarations t; _ -> False) args
  C.Arrow a b -> all (supportedRepresentationWithData target declarations) [a,b]
  _ -> supportedRepresentation target ty

supportedRepresentation :: String -> C.Type -> Bool
supportedRepresentation _ (C.Constructor name []) = maybe False (const True) (primitive name)
supportedRepresentation target (C.Constructor "Either" [C.TypeArgument a,C.TypeArgument b]) =
  target `elem` ["python","javascript","typescript","haskell","java","kotlin","go"] && all (supportedRepresentation target) [a,b]
supportedRepresentation target (C.Constructor name [C.TypeArgument argument]) =
  (name `elem` ["Nullable","Optional"] || name `elem` ["List","Maybe"] && target `elem` ["python","javascript","typescript","haskell","java","kotlin","go"] || name == "List" && target `elem` ["go"])
    && supportedRepresentation target argument
supportedRepresentation target (C.Arrow a b) = supportedRepresentation target a && supportedRepresentation target b
supportedRepresentation _ _ = False

-- Paths and imports are transformed together so custom layouts remain executable.
emitPlanWithLayout :: String -> Maybe String -> Maybe String -> Plan -> Either [Diagnostic] [Artifact]
emitPlanWithLayout = emitPlanWithOptions False

emitPlanWithOptions :: Bool -> String -> Maybe String -> Maybe String -> Plan -> Either [Diagnostic] [Artifact]
emitPlanWithOptions minify target sourceDir testDir plan =
  emitPlanWithNativeOptions minify target sourceDir testDir NB.emptyBindingPlan plan

emitPlanWithNativeOptions :: Bool -> String -> Maybe String -> Maybe String -> NB.BindingPlan -> Plan -> Either [Diagnostic] [Artifact]
emitPlanWithNativeOptions minify target sourceDir testDir unescaped unwitnessed = do
  let originalPlan = escapePlan target (witnessPlan unwitnessed)
      bindings = escapeBindings target unescaped
  unless (target `elem` ["python","rust","javascript","typescript","java","kotlin","go","haskell"] || not (any Binding.resolvedGeneratorStub
    (Binding.resolvedGenerators (NB.bindingRepresentations bindings))))
    (Left [Diagnostic "native-binding" ("generator scaffolds are not implemented for " ++ target) Nothing])
  plan <- if target == "go" && NB.hasBindings bindings
    then either (Left . pure . (\m -> Diagnostic "native-binding" m Nothing)) Right
      (GoNativeBinding.preparePlan bindings originalPlan)
    else Right originalPlan
  unless (target `elem` ["rust","haskell","python","javascript","typescript","java","kotlin","go"] || all ((== Nothing) . Binding.resolvedCodec)
    (Binding.resolvedTypes (NB.bindingRepresentations bindings)))
    (Left [Diagnostic "native-binding" ("codec hook emission is not implemented for " ++ target) Nothing])
  unless (target == "go" || null (NB.bindingGoImports bindings))
    (Left [Diagnostic "native-binding" "goImports is only valid for Go bindings" Nothing])
  emitted <- if not (NB.hasBindings bindings) then emitPlanWithFormat minify target plan
    else if target == "rust" then emitRustWithBindings minify bindings plan
    else if target == "python" then do
      ordinary <- emitPlanWithFormat minify target plan
      either (Left . pure . (\m -> Diagnostic "native-binding" m Nothing)) Right
        (PythonNativeBinding.emitBindings minify bindings plan ordinary)
    else if target `elem` ["javascript","typescript"] then do
      ordinary <- emitPlanWithFormat minify target plan
      either (Left . pure . (\m -> Diagnostic "native-binding" m Nothing)) Right
        (WebNativeBinding.emitBindings (target == "typescript") minify bindings plan ordinary)
    else if target == "java" then do
      ordinary <- emitPlanWithFormat minify target plan
      either (Left . pure . (\m -> Diagnostic "native-binding" m Nothing)) Right
        (JavaNativeBinding.emitBindings minify bindings plan ordinary)
    else if target == "kotlin" then do
      ordinary <- emitPlanWithFormat minify target plan
      either (Left . pure . (\m -> Diagnostic "native-binding" m Nothing)) Right
        (KotlinNativeBinding.emitBindings minify bindings plan ordinary)
    else if target == "haskell" then do
      ordinary <- emitPlanWithFormat minify target plan
      either (Left . pure . (\m -> Diagnostic "native-binding" m Nothing)) Right
        (HaskellNativeBinding.emitBindings minify bindings plan ordinary)
    else if target == "go" then do
      ordinary <- emitPlanWithFormat minify target plan
      either (Left . pure . (\m -> Diagnostic "native-binding" m Nothing)) Right
        (GoNativeBinding.emitBindings minify bindings plan ordinary)
    else Left [Diagnostic "native-binding" ("native binding emission is not implemented for " ++ target) Nothing]
  canonical <- if NB.hasBindings bindings && minify && target == "rust"
    then emitRustWithBindings False bindings plan
    else if NB.hasBindings bindings && minify && target == "python" then do
      ordinary <- emitPlanWithFormat False target plan
      either (Left . pure . (\m -> Diagnostic "native-binding" m Nothing)) Right
        (PythonNativeBinding.emitBindings False bindings plan ordinary)
    else if NB.hasBindings bindings && minify && target `elem` ["javascript","typescript"] then do
      ordinary <- emitPlanWithFormat False target plan
      either (Left . pure . (\m -> Diagnostic "native-binding" m Nothing)) Right
        (WebNativeBinding.emitBindings (target == "typescript") False bindings plan ordinary)
    else if NB.hasBindings bindings && minify && target == "java" then do
      ordinary <- emitPlanWithFormat False target plan
      either (Left . pure . (\m -> Diagnostic "native-binding" m Nothing)) Right
        (JavaNativeBinding.emitBindings False bindings plan ordinary)
    else if NB.hasBindings bindings && minify && target == "kotlin" then do
      ordinary <- emitPlanWithFormat False target plan
      either (Left . pure . (\m -> Diagnostic "native-binding" m Nothing)) Right
        (KotlinNativeBinding.emitBindings False bindings plan ordinary)
    else if NB.hasBindings bindings && minify && target == "haskell" then do
      ordinary <- emitPlanWithFormat False target plan
      either (Left . pure . (\m -> Diagnostic "native-binding" m Nothing)) Right
        (HaskellNativeBinding.emitBindings False bindings plan ordinary)
    else if NB.hasBindings bindings && minify && target == "go" then do
      ordinary <- emitPlanWithFormat False target plan
      either (Left . pure . (\m -> Diagnostic "native-binding" m Nothing)) Right
        (GoNativeBinding.emitBindings False bindings plan ordinary)
    else pure emitted
  files <- if not (NB.hasBindings bindings) then pure emitted else mapM (\artifact -> if ownership artifact /= "user" then pure artifact else
    case lookup (artifactPath artifact) [(artifactPath a,artifactContent a) | a <- canonical, ownership a == "user"] of
      Nothing -> Left [Diagnostic "native-binding" "missing canonical adapter reference" Nothing]
      Just reference -> pure (AdapterArtifact (artifactPath artifact) (artifactContent artifact)
        (ownership artifact) (artifactPlacement artifact) reference)) emitted
  let defaults = case target of
        "java" -> ("src/main/java", "src/test/java")
        "kotlin" -> ("src/main/kotlin", "src/test/kotlin")
        "python" -> ("src", "tests")
        "rust" -> ("src", "tests")
        "go" -> ("", "")
        _ -> ("src", "test")
      src = maybe (fst defaults) id sourceDir
      tst = maybe (snd defaults) id testDir
      safe p = (null p && target == "go") || (not (null p) && all (\part -> not (null part) && part /= "." && part /= ".." && all (\c -> isAlphaNum c || c `elem` ("_-" :: String)) part) (split '/' p))
  unless (safe src && safe tst) (Left [Diagnostic "layout" "output directories must be relative paths without traversal" Nothing])
  unless (target /= "go" || src == tst) (Left [Diagnostic "layout" "Go adapters and tests must share a source directory" Nothing])
  let prefix p f = if null p then f else p ++ "/" ++ f
      move old new f = prefix new (maybe f id (stripPrefix (if null old then "" else old ++ "/") f))
      rel a b = case (a,b) of
        (x:xs,y:ys) | x == y -> rel xs ys
        _ -> intercalate "/" (replicate (length a) ".." ++ b)
      relative = rel (split '/' tst) (split '/' src)
      importRoot = if null relative then "." else if ".." `isPrefixOf` relative then relative else "./" ++ relative
      replace old new text
        | null text = []
        | Just rest <- stripPrefix old text = new ++ replace old new rest
        | c:rest <- text = c:replace old new rest
        | otherwise = []
      sourceBase a = if target == "kotlin" && ".java" `isSuffixOf` artifactPath a then "src/main/java" else fst defaults
      sourceRoot a = if target == "kotlin" && ".java" `isSuffixOf` artifactPath a then maybe "src/main/java" id sourceDir else src
      adjust a = (mapArtifactContent (adjustContent a) a)
        { artifactPath = if artifactPlacement a == "source" then move (sourceBase a) (sourceRoot a) (artifactPath a) else move (snd defaults) tst (artifactPath a) }
      adjustContent a
        | target `elem` ["javascript","typescript"] && artifactPlacement a == "test" =
          let nested = init (split '/' (drop (length (snd defaults) + 1) (artifactPath a)))
              old = concat (replicate (length nested + 1) "../") ++ "src/"
              destination = rel (split '/' tst ++ nested) (split '/' src)
              root = if null destination then "." else if ".." `isPrefixOf` destination
                then destination else "./" ++ destination
          in replace ("from '" ++ old) ("from '" ++ root ++ "/")
        | target == "rust" && artifactPlacement a == "test" = replace "\n#[path = \"../src/" ("\n#[path = \"" ++ importRoot ++ "/")
        | otherwise = id
      result = map adjust files
  unless (length result == length (nub (map (map toLower . artifactPath) result))) (Left [Diagnostic "collision" "custom layout causes an output collision" Nothing])
  pure result

-- The web strategies' schema import, rewritten to the emitted layout.
schemaImport :: String
schemaImport = "import {RefinementViolation, witnessed, witnessInstances} from './lawspec_schema.mjs';"

-- Emitted files are held as text, weighed by their length.
emitTable :: Table (Either [Diagnostic] [Stored])
emitTable = unsafePerformIO (newPersistentTable "emit" 8000000 (either (const 1) (sum . map storedLength)))
{-# NOINLINE emitTable #-}

data Stored = Stored T.Text T.Text T.Text T.Text (Maybe T.Text)

instance Binary Stored where
  put (Stored p c o l canonical) = put p >> put c >> put o >> put l >> put canonical
  get = Stored <$> get <*> get <*> get <*> get <*> get

store :: Artifact -> Stored
store (Artifact p c o l) = Stored (T.pack p) (T.pack c) (T.pack o) (T.pack l) Nothing
store (AdapterArtifact p c o l canonical) = Stored (T.pack p) (T.pack c) (T.pack o) (T.pack l) (Just (T.pack canonical))

unstore :: Stored -> Artifact
unstore (Stored p c o l Nothing) = Artifact (T.unpack p) (T.unpack c) (T.unpack o) (T.unpack l)
unstore (Stored p c o l (Just canonical)) = AdapterArtifact (T.unpack p) (T.unpack c) (T.unpack o) (T.unpack l) (T.unpack canonical)

storedLength :: Stored -> Int
storedLength (Stored _ c _ _ canonical) = T.length c + maybe 0 T.length canonical

-- How each target calls a checked definition on logical values.
remoteCalls :: String -> Plan -> [(C.Id, String)]
remoteCalls target plan = case target of
  "python" -> PythonDefinitions.definitionCalls units
  "rust" -> [(i, "crate::lawspec_definitions::" ++ n) | (i, n) <- RustDefinitions.definitionNames units]
  _ -> []
  where units = map plannedUnit (plannedUnits plan)
