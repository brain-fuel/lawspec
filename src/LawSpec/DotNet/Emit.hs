-- | F# and C# projects from a fully elaborated plan: the LawSpec runtime
-- (F#, with its C# compatibility layer), the program's data and entries,
-- the adapters a user implements and the xUnit tests of its laws. F# lists
-- its files in compilation order, so the generated MSBuild props do.
-- ref:DEC-fsharp-runtime-from-scratch ref:DEC-csharp-over-fsharp
-- ref:DEC-typed-core-boundary
module LawSpec.DotNet.Emit (emitDotNet, emitDotNetWithBindings, dotnetTargets) where

import qualified LawSpec.Core as C
import LawSpec.Core.Machine (machineActor, machineScenarios)
import qualified LawSpec.Code.Doc as D
import LawSpec.Common (Artifact(..), Diagnostic(..), artifactPath)
import LawSpec.Testing
import LawSpec.NativeRequest (BindingPlan(..), NativeCall(..), emptyBindingPlan)
import LawSpec.NativeBinding (ResolvedBindings(..), ResolvedGeneratorBinding(..), ResolvedTypeBinding(..), NativeRef(..))
import LawSpec.DotNetSources (dotnetSource, dotnetFiles)
import LawSpec.DotNet.Code (Lang(..))
import LawSpec.DotNet.Names
import qualified LawSpec.DotNet.Data as Data
import qualified LawSpec.DotNet.Definitions as Definitions
import qualified LawSpec.DotNet.Properties as Properties
import qualified LawSpec.DotNet.Abilities as Abilities
import qualified LawSpec.DotNet.Models as Models
import qualified LawSpec.DotNet.Actors as Actors
import qualified LawSpec.DotNet.Sessions as Sessions
import qualified LawSpec.DotNet.Mailboxes as Mailboxes
import qualified LawSpec.DotNet.Remote as Remote
import qualified LawSpec.DotNet.Handlers as Handlers
import LawSpec.Typed.FSharp (FSharpTyped(..), emitFSharpTyped)
import Control.Monad (unless, when)
import Data.List (isPrefixOf, isSuffixOf, isInfixOf, nub)
import LawSpec.DefaultSources (defaultSource)
import LawSpec.DotNet.Code (stringLiteral)

dotnetTargets :: [String]
dotnetTargets = ["fsharp", "csharp"]

emitDotNet :: String -> Bool -> Plan -> Either [Diagnostic] [Artifact]
emitDotNet target minify = emitDotNetWithBindings target minify emptyBindingPlan

emitDotNetWithBindings :: String -> Bool -> BindingPlan -> Plan -> Either [Diagnostic] [Artifact]
emitDotNetWithBindings target minify bindings plan = do
  unless (all ((== Nothing) . resolvedCodec) boundTypes)
    (Left [Diagnostic "native-binding" ".NET binds a type by its constructors and fields, not by codec functions" Nothing])
  when (lang == CSharp && not (null boundTypes))
    (Left [Diagnostic "native-binding" "C# binds functions and handlers to application code, not types: a C# program uses the generated data types" Nothing])
  diagnose (validatePlan plan)
  emitted <- diagnose (if lang == CSharp then emitCSharp else emit)
  let files = if minify then map compacted emitted else emitted
      paths = map artifactPath files
  unless (length paths == length (nub paths)) (Left [Diagnostic "collision" ".NET units map to the same output path" Nothing])
  pure files
  where
    lang = langOf target
    layout = D.selectLayout minify (D.Pretty 100)
    -- The compact layout drops generated documentation and blank lines; F#
    -- keeps its indentation, which is its syntax. The runtime and the
    -- user's adapters stay as they are.
    compacted artifact@(Artifact path content ownership' placement)
      | ownership' /= "user", any (`isSuffixOf` path) [".fs", ".cs"]
      , not ("lawspec/LawSpec.Runtime/" `isPrefixOf` path || "lawspec/LawSpec.Testing/" `isPrefixOf` path) =
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
      dataFiles <- Data.emitData lang layout bits boundTypes declarations
      interfaces <- Abilities.emitInterfaces lang layout bits declarations units
      bridges <- Abilities.emitBridges lang layout bits declarations units
      defaults <- Abilities.emitDefaults lang layout units
      schema <- Data.emitSchema lang layout bits usesCrypto declarations
      typed <- emitFSharpTyped bits (map (C.dataId . resolvedDeclaration) boundTypes) declarations units
      let typedFile = [Artifact "src/LawSpec/Typed.fs" source "generated" "source" | Just source <- [fsTypedSource typed]]
          typedCall i = (\f -> (f, maybe f id (fsTypedCsFunction typed i), fsTypedContextual typed i)) <$> fsTypedFunction typed i
      entries <- Definitions.emitEntries lang layout bits calls typedCall declarations units
      adapters <- Definitions.emitAdapters lang layout bits calls declarations units
      api <- Definitions.emitApi lang layout bits declarations units
      laws <- Properties.emitTests lang layout (not (null generators)) plan
      nativeGenerators <- Properties.emitNativeGenerators lang layout bits declarations generators
      models <- Models.emitModels lang layout bits declarations units
      let tests = nativeGenerators ++ laws ++ models
      vectors <- cryptoVectorTests
      (actorClasses', actorHandlers) <- if lang == FSharp then Actors.emitActors layout bits declarations units else pure ([], [])
      sessionFiles <- if lang == FSharp then Sessions.emitSessions layout bits declarations units else pure []
      mailboxFiles <- if lang == FSharp then Mailboxes.emitMailboxes layout bits declarations units else pure []
      let (remoteEarly, remoteLate) = if lang == FSharp && usesNetwork then Remote.emitRemote FSharp layout units plan else ([], [])
          actorClasses = sessionFiles ++ mailboxFiles ++ remoteEarly ++ actorClasses'
      handlerClasses <- Handlers.emitHandlers lang layout bits (Just typed) declarations units
      let ordered = orderSources (dataFiles ++ interfaces ++ bridges ++ [schema] ++ defaults ++ typedFile ++ actorClasses) adapters entries api ++
            [drop (4 :: Int) (artifactPath a) | a <- handlerClasses ++ actorHandlers ++ remoteLate]
          sources = dataFiles ++ interfaces ++ bridges ++ [schema] ++ defaults ++ typedFile ++ actorClasses ++ entries ++ adapters ++ api ++ handlerClasses ++ actorHandlers ++ remoteLate
      pure (runtimeArtifacts ++ sources ++ tests ++ vectors ++
        [ props "src/LawSpec.Sources.props" "source" "The program's generated sources and adapters, in compilation order; application types bound in lawspec.json go in Native/Types/, before the data types; other application code goes in Native/, after the ability interfaces." ordered
        , props "tests/LawSpec.Tests.props" "test" "The generated tests; application generators bound in lawspec.json go in Native/, before them."
            (["Native/**/*.fs" | not (null generators)] ++ [drop (6 :: Int) (artifactPath t) | t <- tests ++ vectors]) ])
    orderSources first adapters entries api =
      ["Native/Types/**/*" ++ extension lang] ++ [drop (4 :: Int) (artifactPath a) | a <- first] ++ ["Native/**/*" ++ extension lang] ++
      concat [ [drop (4 :: Int) p | p <- [adapterPath lang (C.unitId u)], p `elem` map artifactPath adapters] ++
               [drop (4 :: Int) (artifactPath e) | e <- entries, ("/" ++ lastModule u ++ extension lang) `isSuffixOf` artifactPath e] ++
               [drop (4 :: Int) (artifactPath a) | a <- api, ("Definitions/" ++ lastModule u ++ extension lang) `isSuffixOf` artifactPath a]
             | u <- Definitions.orderedUnits units ]
    -- C# runs over F#: the program's model (data types, codecs, ability
    -- interfaces and bridges, schema, typed actors, sessions and mailboxes)
    -- is a generated F# project, LawSpec.Model, which the C# project
    -- references; the entries, adapters, embedding API and tests are C#.
    emitCSharp = do
      dataFiles <- Data.emitData FSharp layout bits [] declarations
      interfaces <- Abilities.emitInterfaces FSharp layout bits declarations units
      bridges <- Abilities.emitBridges FSharp layout bits declarations units
      defaults <- Abilities.emitDefaults FSharp layout units
      schema <- Data.emitSchema FSharp layout bits usesCrypto declarations
      sessionFiles <- Sessions.emitSessions layout bits declarations units
      mailboxFiles <- Mailboxes.emitMailboxes layout bits declarations units
      (actorClasses, _) <- Actors.emitActors layout bits declarations units
      actorHandlers <- Actors.emitActorHandlersCs layout bits declarations units
      typed <- emitFSharpTyped bits [] declarations units
      let typedFile = [Artifact "src/LawSpec/Typed.fs" source "generated" "source" | Just source <- [fsTypedSource typed]]
          typedCall i = (\f -> (f, maybe f id (fsTypedCsFunction typed i), fsTypedContextual typed i)) <$> fsTypedFunction typed i
      let (remoteEarly, remoteLate) = if usesNetwork then Remote.emitRemote CSharp layout units plan else ([], [])
          modelFiles = map relocate (dataFiles ++ interfaces ++ bridges ++ [schema] ++ defaults ++ typedFile ++ sessionFiles ++ mailboxFiles ++ remoteEarly ++ actorClasses)
          relocate (Artifact path content ownership _) = Artifact ("lawspec/LawSpec.Model/" ++ drop (length ("src/LawSpec/" :: String)) path) content ownership "source"
          relocate other = other
          modelProject = Artifact "lawspec/LawSpec.Model/LawSpec.Model.fsproj" (unlines (
            [ "<Project Sdk=\"Microsoft.NET.Sdk\">"
            , "  <!-- Generated by LawSpec. Do not edit. The program's model, in F#: its data types, codecs, ability interfaces and schema. -->"
            , "  <PropertyGroup>"
            , "    <TargetFramework>net10.0</TargetFramework>"
            , "    <Nullable>disable</Nullable>"
            , "    <TreatWarningsAsErrors>true</TreatWarningsAsErrors>"
            , "    <IsPackable>false</IsPackable>"
            , "  </PropertyGroup>"
            , "  <ItemGroup>" ] ++
            [ "    <Compile Include=\"" ++ drop (length ("lawspec/LawSpec.Model/" :: String)) (artifactPath a) ++ "\" />" | a <- modelFiles ] ++
            [ "  </ItemGroup>"
            , "  <ItemGroup>"
            , "    <ProjectReference Include=\"../LawSpec.Runtime/LawSpec.Runtime.fsproj\" />"
            , "  </ItemGroup>"
            , "</Project>" ])) "generated" "source"
      entries <- Definitions.emitEntries CSharp layout bits calls typedCall declarations units
      adapters <- Definitions.emitAdapters CSharp layout bits calls declarations units
      api <- Definitions.emitApi CSharp layout bits declarations units
      handlerClasses <- Handlers.emitHandlers CSharp layout bits (Just typed) declarations units
      laws <- Properties.emitTests CSharp layout (not (null generators)) plan
      nativeGenerators <- Properties.emitNativeGenerators CSharp layout bits declarations generators
      models <- Models.emitModels CSharp layout bits declarations units
      let sourcesProps = Artifact "src/LawSpec.Sources.props" (unlines
            [ "<Project>"
            , "  <!-- Generated by LawSpec. Do not edit. The program's model, generated in F#. -->"
            , "  <ItemGroup>"
            , "    <ProjectReference Include=\"../lawspec/LawSpec.Model/LawSpec.Model.fsproj\" />"
            , "  </ItemGroup>"
            , "</Project>" ]) "generated" "source"
          testsProps = Artifact "tests/LawSpec.Tests.props" (unlines
            [ "<Project>"
            , "  <!-- Generated by LawSpec. Do not edit. -->"
            , "</Project>" ]) "generated" "test"
      vectors <- cryptoVectorTests
      pure (runtimeArtifacts ++ modelFiles ++ [modelProject] ++ entries ++ adapters ++ api ++ handlerClasses ++ actorHandlers ++ remoteLate ++ nativeGenerators ++ laws ++ models ++ vectors ++ [sourcesProps, testsProps])
    -- Types bound in lawspec.json come before the data that uses them; the
    -- rest of the application's code after the interfaces it implements.
    exclude f = if f == "Native/**/*" ++ extension lang then " Exclude=\"Native/Types/**\"" else ""
    lastModule u = last (splitDots (generatedModule (C.unitId u)))
    props path placement comment files = Artifact path (unlines (
      [ "<Project>"
      , "  <!-- Generated by LawSpec. Do not edit. " ++ comment ++ " -->" ] ++
      (if lang == FSharp || null files then
        [ "  <ItemGroup>" ] ++ ["    <Compile Include=\"" ++ f ++ "\"" ++ exclude f ++ " />" | lang == FSharp, f <- files] ++ [ "  </ItemGroup>" ]
       else []) ++
      [ "</Project>" ])) "generated" placement
    -- The crypto primitives and Bouncy Castle only for programs that import
    -- lawspec.crypto or lawspec.network, as on the other targets.
    -- The network runtime only for programs with nodes, channels, actors,
    -- mailboxes or scenarios; its secure transport uses the crypto runtime.
    usesNetwork = any (\u -> not (null (C.unitSessions u) && null (C.unitMailboxes u) && null (C.unitSupervisors u)) ||
        any (\m -> machineActor m || not (null (machineScenarios m))) (C.unitMachines u) ||
        C.idText (C.unitId u) == "lawspec.network") units
    usesCrypto = usesNetwork || any ((== "lawspec.crypto") . C.idText . C.unitId) units
    cryptoFiles = ["Crypto.fs", "NetworkCrypto.fs", "CryptoVectors.fs", "BouncyCastle.Cryptography"]
    networkFiles = ["Wire.fs", "MemoryNetwork.fs", "SocketTransport.fs", "Transport.fs", "SecureNetwork.fs", "Node.fs",
      "ChannelProtocol.fs", "Endpoint.fs", "Remote.fs", "Mailbox.fs", "Sessions.fs", "NetworkApi.fs",
      "ScenarioNetwork.fs", "ScenarioIo.fs", "Scenario.fs"]
    excluded = [f | not usesCrypto, f <- cryptoFiles] ++ [f | not usesNetwork, f <- networkFiles]
    keep line = not (any (\f -> ("\"" ++ f ++ "\"") `isInfixOf` line) excluded)
    runtimeArtifacts =
      [ Artifact ("lawspec/" ++ file) (if ".fsproj" `isSuffixOf` file then unlines (filter keep (lines (dotnetSource file))) else dotnetSource file)
          "generated" (if "LawSpec.Testing/" `isPrefixOf` file then "test" else "source")
      | file <- dotnetFiles, not (any (\f -> ("/" ++ f) `isSuffixOf` file) excluded) ]
    cryptoVectorTests
      | not usesCrypto = pure []
      | lang == CSharp = pure [Artifact "tests/LawSpec/CryptoVectors.cs" (unlines (
          [ "// Generated by LawSpec. Do not edit."
          , "namespace LawSpec.Tests;", "", "using Xunit;", ""
          , "/// <summary>lawspec.crypto's primitives against NIST's known-answer vectors.</summary>"
          , "public sealed class CryptoVectors", "{"
          , "    private static readonly string vectors = " ++ stringLiteral CSharp (defaultSource "vectors.txt") ++ ";" ] ++
          concat [ ["", "    [Fact(DisplayName = " ++ stringLiteral CSharp ("crypto vectors " ++ kind) ++ ")]",
                    "    public void " ++ concatMap pascal (words (map (\c -> if c == '-' then ' ' else c) kind)) ++ "() => LawSpec.Testing.CryptoVectors.Check(vectors, " ++ stringLiteral CSharp kind ++ ");"]
                 | kind <- vectorKinds ] ++ ["}"])) "generated" "test"]
      | otherwise = pure [Artifact "tests/LawSpec/CryptoVectors.fs" (unlines (
          [ "// Generated by LawSpec. Do not edit."
          , "/// lawspec.crypto's primitives against NIST's known-answer vectors."
          , "module LawSpec.Tests.CryptoVectors", "", "open Xunit", "open LawSpec.Testing", ""
          , "let private vectors = " ++ stringLiteral FSharp (defaultSource "vectors.txt") ] ++
          concat [ ["", "[<Fact(DisplayName = " ++ stringLiteral FSharp ("crypto vectors " ++ kind) ++ ")>]",
                    "let ``" ++ kind ++ "`` () = CryptoVectors.check vectors " ++ stringLiteral FSharp kind]
                 | kind <- vectorKinds ])) "generated" "test"]
    vectorKinds = ["sha3-256","shake256","aes-256-gcm","mlkem768-keygen","mlkem768-encaps",
      "mlkem768-decaps","mlkem768-decaps-seed","mldsa65-keygen","mldsa65-verify",
      "mldsa65-sign-seed","slhdsa128f-keygen","slhdsa128f-verify"]

-- | Names that would collide in generated .NET code are refused before
-- anything is written.
validatePlan :: Plan -> Either String ()
validatePlan plan = do
  let units = map plannedUnit (plannedUnits plan)
      modules = map (unitQualified . C.unitId) units
  unless (length modules == length (nub modules)) (Left ".NET unit modules collide after PascalCase conversion")
  unless (all (\u -> not ("LawSpec" `isPrefixOf` unitQualified (C.unitId u))) [u | u <- units, not (null (Definitions.adapterDeclarations u))])
    (Left "a unit with adapters cannot be named in the LawSpec namespace on .NET")
  pure ()
