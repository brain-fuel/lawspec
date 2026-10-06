-- lawspec.network: the secure network handler, only for programs that ask
-- for it. A program that imports lawspec.network gets, beside each runtime
-- file, the target's network module (runtime/<lawspec_network>), which holds
-- node identities, the handshake and sealed frames, and so depends on the
-- crypto libraries; other programs do without them. Nodes find the module
-- when they are made (Python, JavaScript, Java and Kotlin load it; in Go it
-- registers itself; in Rust and Haskell lawspec_network's install registers
-- it, and the generated tests call it).
module LawSpec.Network
  ( networkUnit, networkSource, usesNetwork, usesNetworkUnits, withNetworkModules, cryptoUsed
  ) where

import Data.List (isInfixOf, isPrefixOf, stripPrefix)
import Data.Maybe (mapMaybe)
import qualified LawSpec.Core as C
import LawSpec.Common (Artifact(..))
import LawSpec.RuntimeSources (runtimeSource)

networkUnit :: String
networkUnit = "lawspec.network"

networkSource :: String
networkSource = unlines
  [ "unit lawspec.network"
  , ""
  , "-- The secure network handler: importing this unit gives a program's nodes"
  , "-- ML-DSA-65 identities, a signed ML-KEM-768 handshake and frames sealed"
  , "-- with AES-256-GCM (docs/reference/language/distribution.md#security)."
  ]

usesNetworkUnits :: [C.Unit] -> Bool
usesNetworkUnits = any ((== networkUnit) . C.idText . C.unitId)

-- Whether a program's source imports lawspec.network (for its unit list).
usesNetwork :: [String] -> Bool
usesNetwork = elem networkUnit

-- Whether a program needs the crypto libraries: it imports lawspec.crypto or
-- lawspec.network.
cryptoUsed :: [String] -> Bool
cryptoUsed units = any (`elem` units) ["lawspec.crypto", networkUnit]

-- The network module beside each runtime file, for a program that uses it;
-- Rust also declares it among the crate's modules.
withNetworkModules :: String -> Bool -> [Artifact] -> [Artifact]
withNetworkModules target uses files
  | not uses = files
  | otherwise = map declare files ++ mapMaybe sibling files
  where
    sibling a = do
      (directory, name) <- Just (splitPath (artifactPath a))
      (file, source, prefix) <- case name of
        "lawspec_runtime.py" -> Just ("lawspec_network.py", "python-network", "")
        "lawspec_runtime.mjs" -> Just ("lawspec_network.mjs", "javascript-network", "")
        "lawspec_runtime.ts" -> Just ("lawspec_network.ts", "javascript-network", "// @ts-nocheck\n")
        "LawSpecRuntime.java" -> Just ("LawSpecNetwork.java", "java-network", "")
        "lawspec_runtime.go" -> Just ("lawspec_network.go", "go-network", "")
        "LawSpecRuntime.hs" -> Just ("LawSpecNetwork.hs", "haskell-network", "")
        "lawspec_runtime.rs" | "src/" `isPrefixOf` artifactPath a -> Just ("lawspec_network.rs", "rust-network", "")
        _ -> Nothing
      let content = prefix ++ (if target == "go" then goPackage (artifactContent a) else id) (runtimeSource source)
      Just (Artifact (directory ++ file) content (ownership a) (artifactPlacement a))
    declare a
      | target == "rust" && artifactPath a == "src/lawspec_modules.rs" =
          a { artifactContent = artifactContent a ++ "#[path = \"lawspec_network.rs\"]\npub mod lawspec_network;\n" }
      -- Rust and Haskell tests install the module before their laws run.
      | target == "rust" && artifactPlacement a == "test" && "ls::Context::testing();" `isInfixOf` artifactContent a =
          a { artifactContent =
                replace "let ctx = &mut ls::Context::testing();" "lawspec_network::install(); let ctx = &mut ls::Context::testing();" $
                replace "#[path = \"../src/lawspec_runtime.rs\"]\nmod lawspec_runtime;"
                  "#[path = \"../src/lawspec_runtime.rs\"]\nmod lawspec_runtime;\n#[path = \"../src/lawspec_network.rs\"]\nmod lawspec_network;" $
                mountLibrary (artifactContent a) }
      | target == "haskell" && artifactPlacement a == "test" && "runIO (LS.useVirtualClock 0)" `isInfixOf` artifactContent a =
          a { artifactContent =
                replace "runIO (LS.useVirtualClock 0)" "runIO (LS.useVirtualClock 0)\n  runIO LawSpecNetwork.install" $
                replace "import qualified LawSpecRuntime as LS\n" "import qualified LawSpecRuntime as LS\nimport qualified LawSpecNetwork\n" (artifactContent a) }
      | otherwise = a
    -- A test of a bound library crate uses the library's module.
    mountLibrary content = case [l | l <- lines content, "use " `isPrefixOf` l, "::lawspec_runtime;" `isInfixOf` l] of
      l : _ -> replace (l ++ "\n") (l ++ "\n" ++ replace "::lawspec_runtime;" "::lawspec_network;" l ++ "\n") content
      [] -> content
    -- The runtime copy's package, for the module beside it.
    goPackage runtime = replace "RUNTIME_PACKAGE"
      (head ([p | l <- lines runtime, Just p <- [stripPrefix "package " l]] ++ ["main"]))
    splitPath p = let (file, rest) = break (== '/') (reverse p) in (reverse rest, reverse file)
    replace old new s = case s of
      [] -> []
      c : rest | old `isPrefixOf` s -> new ++ replace old new (drop (length old) s)
               | otherwise -> c : replace old new rest

