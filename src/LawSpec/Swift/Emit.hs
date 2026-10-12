-- | Swift packages from a fully elaborated plan: the LawSpec runtime and test
-- support as SwiftPM targets of their own, the program's data, protocols and
-- entries, the adapters a user implements, and the Swift Testing tests of its
-- laws. ref:DEC-swift-runtime-from-scratch ref:DEC-typed-core-boundary
module LawSpec.Swift.Emit (emitSwift, emitSwiftWithBindings) where

import qualified LawSpec.Core as C
import LawSpec.Core.Machine (machineActor, machineScenarios)
import qualified LawSpec.Code.Doc as D
import LawSpec.Common (Artifact(..), Diagnostic(..), artifactPath)
import LawSpec.Testing
import LawSpec.NativeRequest (BindingPlan(..), NativeCall(..), emptyBindingPlan)
import LawSpec.NativeBinding (ResolvedBindings(..), ResolvedGeneratorBinding(..), ResolvedTypeBinding(..), NativeRef(..))
import LawSpec.SwiftSources (swiftSource, swiftFiles)
import LawSpec.DefaultSources (defaultSource)
import LawSpec.Swift.Code (stringLiteral)
import LawSpec.Swift.Names
import qualified LawSpec.Swift.Data as Data
import qualified LawSpec.Swift.Definitions as Definitions
import qualified LawSpec.Swift.Properties as Properties
import qualified LawSpec.Swift.Abilities as Abilities
import qualified LawSpec.Swift.Handlers as Handlers
import qualified LawSpec.Swift.Models as Models
import LawSpec.Typed.Swift (SwiftTyped(..), emitSwiftTyped)
import Control.Monad (unless)
import Data.List (isPrefixOf, isSuffixOf, nub, sort, intercalate)

emitSwift :: Bool -> Plan -> Either [Diagnostic] [Artifact]
emitSwift minify = emitSwiftWithBindings minify emptyBindingPlan

emitSwiftWithBindings :: Bool -> BindingPlan -> Plan -> Either [Diagnostic] [Artifact]
emitSwiftWithBindings minify bindings plan = do
  unless (all ((== Nothing) . resolvedCodec) boundTypes)
    (Left [Diagnostic "native-binding" "Swift binds a type by its constructors and fields, not by codec functions" Nothing])
  diagnose (validatePlan plan)
  emitted <- diagnose emit
  let files = if minify then map compacted emitted else emitted
      paths = map artifactPath files
      -- SwiftPM compiles a target's files by their names alone, so two
      -- files of one target may not share a name.
      targetsOf p = takeWhile (/= '/') p ++ (if "lawspec/" `isPrefixOf` p then "/" ++ takeWhile (/= '/') (drop 8 p) else "")
      basename = reverse . takeWhile (/= '/') . reverse
      keys = [(targetsOf p, basename p) | p <- paths, ".swift" `isSuffixOf` p]
      clashes = nub [b | k@(_, b) <- keys, length (filter (== k) keys) > 1]
  unless (length paths == length (nub paths)) (Left [Diagnostic "collision" "Swift units map to the same output path" Nothing])
  unless (null clashes) (Left [Diagnostic "collision" ("Swift files of one module share a name (SwiftPM compiles files by name): " ++ intercalate ", " clashes ++ "; rename a unit") Nothing])
  pure files
  where
    layout = D.selectLayout minify (D.Pretty 100)
    -- The compact layout drops generated documentation and blank lines. The
    -- runtime and the user's adapters stay as they are.
    compacted artifact@(Artifact path content ownership' placement)
      | ownership' /= "user", ".swift" `isSuffixOf` path, not ("lawspec/" `isPrefixOf` path) =
          Artifact path (unlines [l | l <- lines content, not (blank l), not ("///" `isPrefixOf` dropWhile (== ' ') l)]) ownership' placement
      | otherwise = artifact
    compacted artifact = artifact
    blank = all (== ' ')
    bits = planMachineBits plan
    declarations = planDataDeclarations plan
    units = map plannedUnit (plannedUnits plan)
    boundTypes = resolvedTypes (bindingRepresentations bindings)
    generators = [(resolvedGeneratorType g, referenceParts (resolvedGeneratorFactory g), generatorParameterCount g)
                 | g <- resolvedGenerators (bindingRepresentations bindings)]
    calls = [(C.declarationId d, StaticCall ref) | (d, ref) <- bindingFunctions bindings] ++
      [(C.declarationId d, c) | (d, c) <- bindingCalls bindings]
    diagnose = either (Left . pure . (\message -> Diagnostic "target" message Nothing)) Right
    emit = do
      dataFiles <- Data.emitData layout bits boundTypes declarations
      protocols <- Abilities.emitProtocols layout bits declarations units
      bridges <- Abilities.emitBridges layout bits declarations units
      defaults <- Abilities.emitDefaults layout units
      schema <- Data.emitSchema layout bits usesCrypto declarations
      typed <- emitSwiftTyped bits (map (C.dataId . resolvedDeclaration) boundTypes) declarations units
      let typedFile = [Artifact "src/LawSpec/LawSpecTypedProgram.swift" source "generated" "source" | Just source <- [swiftTypedSource typed]]
          typedCall i = (\f -> (f, swiftTypedContextual typed i)) <$> swiftTypedFunction typed i
      entries <- Definitions.emitEntries layout bits calls typedCall declarations units
      adapters <- Definitions.emitAdapters layout bits calls declarations units
      api <- Definitions.emitApi layout bits declarations units
      handlerClasses <- Handlers.emitHandlers layout bits typed declarations units
      laws <- Properties.emitTests layout (not (null generators)) plan
      nativeGenerators <- Properties.emitNativeGenerators layout bits declarations generators
      models <- Models.emitModels layout bits declarations units
      vectors <- cryptoVectorTests
      pure (runtimeArtifacts ++ [namespaces] ++ dataFiles ++ protocols ++ bridges ++ [schema] ++ defaults ++ typedFile ++ entries ++ adapters ++ api ++ handlerClasses ++
        [Properties.emitRootSuites] ++ nativeGenerators ++ laws ++ models ++ vectors)
    -- The enums every generated name lives in: LawSpec's, and each unit's
    -- namespace, which its adapter extends.
    namespaces = Artifact "src/LawSpec/LawSpecNamespaces.swift" (unlines (
      [ "// Generated by LawSpec. Do not edit."
      , ""
      , "/// LawSpec's generated code for this program."
      , "public enum LawSpec {"
      , "    /// Each unit's entries, on portable values."
      , "    public enum Generated {}"
      , "    /// Each unit's checked definitions, on native values."
      , "    public enum Definitions {}"
      , "    /// Each unit's abilities, as native protocols."
      , "    public enum Abilities {}"
      , "    /// Each unit's spec handlers, as native classes."
      , "    public enum Handlers {}"
      , "}" ] ++ concatMap (\t -> "" : tree 0 t) (forest (nub (sort [splitDots (C.idText (C.unitId u)) | u <- units, not (null (C.unitDeclarations u)) || not (null (C.unitAbilities u))]))))) "generated" "source"
    forest :: [[String]] -> [Namespace]
    forest paths = [ Namespace root (forest [rest | p <- paths, (r : rest@(_ : _)) <- [p], r == root]) | root <- nub [r | (r : _) <- paths] ]
    tree :: Int -> Namespace -> [String]
    tree depth (Namespace name children) =
      let indent = replicate (4 * depth) ' '
      in if null children
        then [indent ++ "public enum " ++ pascal name ++ " {}"]
        else [indent ++ "public enum " ++ pascal name ++ " {"] ++ concatMap (tree (depth + 1)) children ++ [indent ++ "}"]
    -- The crypto primitives only for programs that import lawspec.crypto or
    -- lawspec.network, as on the other targets; the network runtime only for
    -- programs with nodes, channels, actors, mailboxes or scenarios.
    usesNetwork = any (\u -> not (null (C.unitSessions u) && null (C.unitMailboxes u) && null (C.unitSupervisors u)) ||
        any (\m -> machineActor m || not (null (machineScenarios m))) (C.unitMachines u) ||
        C.idText (C.unitId u) == "lawspec.network") units
    usesCrypto = usesNetwork || any ((== "lawspec.crypto") . C.idText . C.unitId) units
    cryptoFiles = ["Keccak.swift", "MLKEM.swift", "MLDSA.swift", "SLHDSA.swift", "CryptoPrimitives.swift", "Crypto.swift", "NetworkCrypto.swift", "CryptoVectors.swift"]
    networkFiles = ["Wire.swift", "MemoryNetwork.swift", "SocketTransport.swift", "Transport.swift", "SecureNetwork.swift", "Node.swift",
      "ChannelProtocol.swift", "Endpoint.swift", "Remote.swift", "Mailbox.swift", "Sessions.swift", "NetworkApi.swift",
      "ScenarioNetwork.swift", "ScenarioIo.swift", "Scenario.swift"]
    excluded = [f | not usesCrypto, f <- cryptoFiles] ++ [f | not usesNetwork, f <- networkFiles]
    runtimeArtifacts =
      [ Artifact ("lawspec/" ++ file) (swiftSource file) "generated" (if "LawSpecTesting/" `isPrefixOf` file then "test" else "source")
      | file <- swiftFiles, not (any (\f -> ("/" ++ f) `isSuffixOf` file) excluded) ]
    cryptoVectorTests
      | not usesCrypto = pure []
      | otherwise = pure [Artifact "tests/LawSpec/CryptoVectors.swift" (unlines (
          [ "// Generated by LawSpec. Do not edit."
          , "import Testing"
          , "import LawSpecTesting"
          , ""
          , "private let vectors = " ++ stringLiteral (defaultSource "vectors.txt")
          , ""
          , "extension LawSpecTests {"
          , "    /// lawspec.crypto's primitives against NIST's known-answer vectors."
          , "    @Suite(\"crypto vectors\") struct CryptoVectorTests {" ] ++
          intercalate [""] [ [ "        @Test(" ++ stringLiteral ("crypto vectors " ++ kind) ++ ")"
                             , "        func " ++ camel kind ++ "() throws {"
                             , "            try CryptoVectors.check(vectors, " ++ stringLiteral kind ++ ")"
                             , "        }" ]
                           | kind <- vectorKinds ] ++
          [ "    }", "}" ])) "generated" "test"]
    vectorKinds = ["sha3-256","shake256","aes-256-gcm","mlkem768-keygen","mlkem768-encaps",
      "mlkem768-decaps","mlkem768-decaps-seed","mldsa65-keygen","mldsa65-verify",
      "mldsa65-sign-seed","slhdsa128f-keygen","slhdsa128f-verify"]

-- | A unit namespace and the namespaces inside it.
data Namespace = Namespace String [Namespace]

-- | Names that would collide in generated Swift code are refused before
-- anything is written.
validatePlan :: Plan -> Either String ()
validatePlan plan = do
  let units = map plannedUnit (plannedUnits plan)
      roots = nub [pascal (head (splitDots (C.idText (C.unitId u)))) | u <- units]
      qualifieds = map (unitQualified . C.unitId) units
  unless (length qualifieds == length (nub qualifieds)) (Left "Swift unit namespaces collide after UpperCamelCase conversion")
  unless (all (`notElem` [moduleName, testModuleName, "LawSpec", "LawSpecRuntime", "LawSpecTesting", "Testing", "Swift", "Foundation"]) roots)
    (Left ("a unit's first name part cannot be any of App, AppTests, LawSpec, LawSpecRuntime, LawSpecTesting, Testing, Swift or Foundation on Swift: " ++ intercalate ", " roots))
