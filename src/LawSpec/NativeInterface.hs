-- | Native inspection uses emitter name allocation and the actual generation
-- plan. Adapter signatures are the canonical readable stubs, never a guessed
-- second ABI. Structural targets retain their schema identities.
-- ref:DEC-authoring-advisories
module LawSpec.NativeInterface (interfaceView) where

import Data.Aeson
import Data.List (nub)
import LawSpec.Digest (digestString, digestHex)
import qualified LawSpec.Core as C
import LawSpec.Common (Artifact(..), adapterReference)
import LawSpec.Testing (Plan(..))
import qualified LawSpec.NativeRequest as N
import qualified LawSpec.NativeBinding as B
import qualified LawSpec.WebTypes as Web
import qualified LawSpec.PythonTypes as Python
import qualified LawSpec.JavaData as Java
import qualified LawSpec.KotlinData as Kotlin
import qualified LawSpec.ScalaData as Scala
import qualified LawSpec.GoData as Go
import qualified LawSpec.HaskellData as Haskell
import qualified LawSpec.RustData as Rust
import qualified LawSpec.DotNet.Names as DotNet
import qualified LawSpec.Swift.Names as Swift
import qualified LawSpec.BeamCode as Beam
import LawSpec.Targets (artifactTargets)

-- | The compact layout is given as each file's path and SHA-256: a generated
-- file is recognized by the digest of either layout.
interfaceView :: String -> N.BindingPlan -> Plan -> [Artifact] -> [(FilePath, String)] -> Either String Value
interfaceView target bindings plan files compact = do
  names <- if target `elem` artifactTargets then pure [] else allocate
  pure (object
    ["target" .= target, "nativeAnalysis" .= (if target `elem` artifactTargets then "not-applicable" else "applicable" :: String),
     "data" .= [object ["declaration" .= C.idText (C.dataId d),
       "nativeName" .= (if null (bound d) then lookup (C.dataId d) names else Nothing),
       "generatedName" .= lookup (C.dataId d) names,
       "ownership" .= (if null (bound d) then "generated" else "bound" :: String),
       "nativeBinding" .= [B.referenceParts (B.resolvedNativeType b) | b <- bound d],
       "constructors" .= [object ["declaration" .= C.idText (C.constructorId c),
         "allocatedName" .= lookup (C.constructorId c) names,
         "schemaIdentity" .= C.idText (C.constructorId c),
         "nativeBinding" .= [B.referenceParts (B.resolvedNativeConstructor rc) |
           b <- bound d, rc <- B.resolvedConstructors b, C.constructorId (B.resolvedConstructor rc) == C.constructorId c]] |
         c <- C.dataConstructors d]] | d <- declarations],
     "artifacts" .= files,
     "generatedDigests" .= [object ["path" .= artifactPath file,
       "sha256" .= nub (digestHex (digestString (artifactContent file)) :
         [other | (path, other) <- compact, path == artifactPath file])]
       | file <- files, ownership file == "generated"],
     "adapters" .= [object ["path" .= artifactPath file, "ownership" .= ownership file,
       "requiredSource" .= maybe (artifactContent file) id (adapterReference file)] | file <- files, ownership file == "user"],
     "construction" .= ("Use the emitted source and schema for constructor layout; allocatedName is null when the shared allocator has no separate constructor entry; the emitted API and schema retain the constructor layout." :: String)])
  where
    declarations = planDataDeclarations plan
    bound d = [b | b <- B.resolvedTypes (N.bindingRepresentations bindings), C.dataId (B.resolvedDeclaration b) == C.dataId d]
    allocate = case target of
      "javascript" -> Web.namesFor declarations
      "typescript" -> Web.namesFor declarations
      "python" -> Python.namesFor declarations
      "prolog" -> pure [(C.dataId d, C.idText (C.dataId d)) | d <- declarations]
      "java" -> map (\(identity,name) -> (C.Id identity,name)) <$> Java.namesFor declarations
      "groovy" -> map (\(identity,name) -> (C.Id identity,name)) <$> Java.namesFor declarations
      "clojure" -> map (\(identity,name) -> (C.Id identity,name)) <$> Java.namesFor declarations
      "kotlin" -> Kotlin.namesFor declarations
      "scala" -> Scala.namesFor declarations
      "go" -> Go.namesFor declarations
      "haskell" -> Haskell.namesFor declarations
      "rust" -> map (\(identity,name) -> (C.Id identity,name)) <$> Rust.namesFor declarations
      "fsharp" -> DotNet.dataNames declarations
      "csharp" -> DotNet.dataNames declarations
      "swift" -> Swift.dataNames declarations
      "erlang" -> Beam.dataNames declarations
      "elixir" -> Beam.dataNames declarations
      "gleam" -> Beam.dataNames declarations
      _ -> Left ("unknown target: " ++ target)
