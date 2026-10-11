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
import LawSpec.NativeBinding (ResolvedBindings(..))
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
  unless (null (resolvedGenerators (bindingRepresentations bindings)))
    (Left [Diagnostic "native-binding" ".NET does not bind native generators yet" Nothing])
  when (lang == CSharp && (not (null boundTypes) || not (null calls)))
    (Left [Diagnostic "native-binding" "C# native type and function bindings are not emitted yet" Nothing])
  diagnose (validatePlan plan)
  files <- diagnose emit
  let paths = map artifactPath files
  unless (length paths == length (nub paths)) (Left [Diagnostic "collision" ".NET units map to the same output path" Nothing])
  pure files
  where
    lang = langOf target
    layout = D.selectLayout minify (D.Pretty 100)
    bits = planMachineBits plan
    declarations = planDataDeclarations plan
    units = map plannedUnit (plannedUnits plan)
    boundTypes = resolvedTypes (bindingRepresentations bindings)
    calls = [(C.declarationId d, StaticCall ref) | (d, ref) <- bindingFunctions bindings] ++
      [(C.declarationId d, c) | (d, c) <- bindingCalls bindings]
    diagnose = either (Left . pure . (\message -> Diagnostic "target" message Nothing)) Right
    emit = do
      dataFiles <- Data.emitData lang layout bits boundTypes declarations
      interfaces <- Abilities.emitInterfaces lang layout bits declarations units
      bridges <- Abilities.emitBridges lang layout bits declarations units
      defaults <- Abilities.emitDefaults lang layout units
      schema <- Data.emitSchema lang layout bits usesCrypto declarations
      entries <- Definitions.emitEntries lang layout bits calls declarations units
      adapters <- Definitions.emitAdapters lang layout bits calls declarations units
      api <- Definitions.emitApi lang layout bits declarations units
      laws <- Properties.emitTests lang layout plan
      models <- Models.emitModels lang layout bits declarations units
      let tests = laws ++ models
      vectors <- cryptoVectorTests
      (actorClasses', actorHandlers) <- if lang == FSharp then Actors.emitActors layout bits declarations units else pure ([], [])
      sessionFiles <- if lang == FSharp then Sessions.emitSessions layout bits declarations units else pure []
      mailboxFiles <- if lang == FSharp then Mailboxes.emitMailboxes layout bits declarations units else pure []
      let (remoteEarly, remoteLate) = if lang == FSharp && usesNetwork then Remote.emitRemote layout units plan else ([], [])
          actorClasses = sessionFiles ++ mailboxFiles ++ remoteEarly ++ actorClasses'
      let ordered = orderSources (dataFiles ++ interfaces ++ bridges ++ [schema] ++ defaults ++ actorClasses) adapters entries api ++
            [drop (4 :: Int) (artifactPath a) | a <- actorHandlers ++ remoteLate]
          sources = dataFiles ++ interfaces ++ bridges ++ [schema] ++ defaults ++ actorClasses ++ entries ++ adapters ++ api ++ actorHandlers ++ remoteLate
      pure (runtimeArtifacts ++ sources ++ tests ++ vectors ++
        [ props "src/LawSpec.Sources.props" "source" "The program's generated sources and adapters, in compilation order; application types bound in lawspec.json go in Native/Types/, before the data types; other application code goes in Native/, after the ability interfaces." ordered
        , props "tests/LawSpec.Tests.props" "test" "The generated tests." [drop (6 :: Int) (artifactPath t) | t <- tests ++ vectors] ])
    orderSources first adapters entries api =
      ["Native/Types/**/*" ++ extension lang] ++ [drop (4 :: Int) (artifactPath a) | a <- first] ++ ["Native/**/*" ++ extension lang] ++
      concat [ [drop (4 :: Int) p | p <- [adapterPath lang (C.unitId u)], p `elem` map artifactPath adapters] ++
               [drop (4 :: Int) (artifactPath e) | e <- entries, ("/" ++ lastModule u ++ extension lang) `isSuffixOf` artifactPath e] ++
               [drop (4 :: Int) (artifactPath a) | a <- api, ("Definitions/" ++ lastModule u ++ extension lang) `isSuffixOf` artifactPath a]
             | u <- Definitions.orderedUnits units ]
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
      | not usesCrypto || lang /= FSharp = pure []
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
