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

import Data.List (isPrefixOf)
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
  , "end unit" ]

usesNetworkUnits :: [C.Unit] -> Bool
usesNetworkUnits = any ((== networkUnit) . C.idText . C.unitId)

-- Whether a program's source imports lawspec.network (for its unit list).
usesNetwork :: [String] -> Bool
usesNetwork = elem networkUnit

-- Whether a program needs the crypto libraries: it imports lawspec.crypto or
-- lawspec.network.
cryptoUsed :: [String] -> Bool
cryptoUsed units = any (`elem` units) ["lawspec.crypto", networkUnit]

-- | Companion runtime modules, selected from checked unit/package metadata.
-- Test headers and initialization belong to their structured target emitters.
withNetworkModules :: String -> [C.Unit] -> [Artifact] -> Either String [Artifact]
withNetworkModules target units files
  | not (usesNetworkUnits units) = Right files
  | otherwise = (filter (not . replaced) files ++) . concat <$> mapM sibling files
  where
    packages = [(map (\c -> if c == '.' then '/' else c) identity ++ "/", lastPart identity)
      | unit <- units, let identity = C.idText (C.unitId unit)]
    sibling artifact = case splitPath (artifactPath artifact) of
      (directory, name) -> case moduleFor name of
        Nothing -> pure []
        Just (filename, source, prefix) -> do
          content <- if target == "go"
            then case lookup directory packages of
              Nothing -> Left ("no checked Go package for network runtime at " ++ artifactPath artifact)
              Just package -> pure (replace "RUNTIME_PACKAGE" package (runtimeSource source))
            else pure (runtimeSource source)
          pure [Artifact (directory ++ filename) (prefix ++ content) (ownership artifact) (artifactPlacement artifact)]
    moduleFor name = case name of
      "lawspec_runtime.py" -> Just ("lawspec_network.py", "python-network", "")
      "lawspec_runtime.mjs" -> Just ("lawspec_network.mjs", "javascript-network", "")
      "lawspec_runtime.ts" -> Just ("lawspec_network.ts", "javascript-network", "// @ts-nocheck\n")
      "LawSpecRuntime.java" -> Just ("LawSpecNetwork.java", "java-network", "")
      "lawspec_runtime.go" -> Just ("lawspec_network.go", "go-network", "")
      "LawSpecRuntime.hs" -> Just ("LawSpecNetwork.hs", "haskell-network", "")
      "lawspec_runtime.rs" -> Just ("lawspec/network.rs", "rust-network", "")
      _ -> Nothing
    replaced artifact = target == "rust" && artifactPath artifact == "src/lawspec/network.rs"
    lastPart value = reverse (takeWhile (/= '.') (reverse value))
    splitPath value = let (name, directory) = break (== '/') (reverse value) in (reverse directory, reverse name)
    -- A reviewed runtime template placeholder, never previously generated code.
    replace old new value = case value of
      [] -> []
      c : rest | old `isPrefixOf` value -> new ++ replace old new (drop (length old) value)
               | otherwise -> c : replace old new rest
