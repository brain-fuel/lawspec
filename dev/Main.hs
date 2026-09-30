-- Development checks for the LawSpec repository. Run from the repository root:
--
--   lawspec-dev boundaries          Core/backends never import syntax or inference
--   lawspec-dev integrity           npm/build.json matches sources and artifacts,
--                                   and staged npm copies match their sources
--   lawspec-dev integrity --record  rewrite npm/build.json (tools/wasm.sh)
--   lawspec-dev ci [options]        the complete check; see dev/Ci.hs
--   lawspec-dev generate [--check]  generated JavaScript and runtimes; see dev/Generate.hs
--   lawspec-dev version [--check]   the release version
--   lawspec-dev bump <x.y.z>        set the release version everywhere
--   lawspec-dev docs [--check]      the documentation site; see dev/Docs.hs
module Main (main) where

import Control.Monad (forM, forM_, unless, when)
import Ci (ci)
import Docs (docsCommand)
import Generate (bumpCommand, generateCommand, versionCommand)
import qualified Crypto.Hash.SHA256 as SHA256
import qualified Data.ByteString as B
import Data.Char (intToDigit)
import Data.List (intercalate, isPrefixOf, isSuffixOf, sort, stripPrefix)
import Data.Maybe (mapMaybe)
import qualified Data.Set as S
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.Environment (getArgs)
import System.Exit (die)
import System.FilePath ((</>))

main :: IO ()
main = getArgs >>= \case
  ["boundaries"] -> boundaries
  ["integrity"] -> integrity False
  ["integrity", "--record"] -> integrity True
  "ci" : options -> ci options
  "generate" : options -> generateCommand options
  "version" : options -> versionCommand options
  "bump" : options -> bumpCommand options
  "docs" : options -> docsCommand options
  _ -> die "usage: lawspec-dev boundaries | integrity [--record] | ci [options] | generate [--check|--list] | version [--check] | bump <x.y.z> | docs --out <dir> | docs --check"

-- Follow transitive local imports, so a convenience module cannot hide
-- syntax or inference behind Core, the testing plan, or an emitter.
boundaries :: IO ()
boundaries = do
  seen <- visitAll S.empty [(root, []) | root <- roots]
  putStrLn ("Core and all eight emitters: " ++ show (S.size seen) ++
    " modules satisfy the syntax/inference boundary.")
  where
    forbidden = S.fromList ["Model", "Parser", "Compile", "Inference", "Elaboration",
      "Frontend", "Refinement", "Domain", "Eval", "Public", "Api"]
    roots = ["Core", "Core.Validate", "Core.Total", "Core.Definitions", "Core.Eval",
      "Core.Payload", "Core.Semantics", "Testing", "Backend", "CoreEmit", "JavaData",
      "RustEmit", "CoreScalarEmit", "CoreNativeScalarEmit", "KotlinData"]
    visitAll seen [] = pure seen
    visitAll seen ((name, trail) : rest) = do
      when (name `S.member` forbidden)
        (die ("Core/backend boundary violation: " ++ intercalate " -> " (reverse (name : trail))))
      if name `S.member` seen then visitAll seen rest else do
        source <- readFile ("src/LawSpec" </> map (\c -> if c == '.' then '/' else c) name ++ ".hs")
        let imports = mapMaybe localImport (lines source)
        visitAll (S.insert name seen) ([(i, name : trail) | i <- imports] ++ rest)
    localImport line = do
      rest <- stripPrefix "import " line
      let unqualified = maybe rest dropSpaces (stripPrefix "qualified " (dropSpaces rest))
      module' <- stripPrefix "LawSpec." (dropSpaces unqualified)
      pure (takeWhile (\c -> c `notElem` (" (" :: String)) module')
    dropSpaces = dropWhile (== ' ')

-- Every compiler source and generated npm artifact is fingerprinted, so a
-- published package can never pair a WASM build with different sources.
integrity :: Bool -> IO ()
integrity record = do
  haskell <- walk (".hs" `isSuffixOf`) "src"
  wasmApp <- walk (".hs" `isSuffixOf`) "wasm/app"
  runtimes <- walk runtimeFile "runtime"
  let sources = sort (haskell ++ wasmApp ++ runtimes ++
        [ "dev/Gen/Embed.hs", "package.yaml", "lawspec.cabal", "stack.yaml"
        , "stack.yaml.lock", "wasm/cabal.project", "wasm/cabal.project.freeze"
        , "wasm/lawspec-wasm.cabal" ])
      artifacts = ["npm/core.wasm", "npm/core_jsffi.js", "npm/api.mjs", "npm/index.d.ts"]
  digests <- forM (sources ++ artifacts) $ \file -> (,) file . hex . SHA256.hash <$> B.readFile file
  if record
    then writeFile "npm/build.json" (render sources digests)
    else do
      stagedCopies
      recorded <- readFile "npm/build.json"
      unless (recorded == render sources digests) $ do
        let stale = [file | (file, digest) <- digests, not (quoted digest `isInfixOf'` recorded
                      && quoted file `isInfixOf'` recorded)]
        die (case stale of
          file : _ -> "Stale build artifact/source: " ++ file ++ "; run tools/wasm.sh"
          [] -> "Compiler source set changed; run tools/wasm.sh")
      putStrLn "WASM, generated API, and compiler source fingerprints match."
  where
    runtimeFile p = any (`isSuffixOf` p) [".rs", ".py", ".mjs", ".ts", ".java", ".kt", ".go", ".hs"]
      || any (`isSuffixOf` p) ["Cargo.toml", "Cargo.lock"]
    quoted s = "\"" ++ s ++ "\""
    isInfixOf' needle haystack = any (needle `isPrefixOf`) (tails' haystack)
    tails' [] = [[]]
    tails' s@(_ : rest) = s : tails' rest

-- tools/wasm.sh stages documentation and examples into npm/. They stay
-- committed because CI jobs without Haskell pack and run the package, so every
-- staged copy must be byte-identical to its source.
stagedCopies :: IO ()
stagedCopies = do
  specs <- filter (".lawspec" `isSuffixOf`) . sort <$> listDirectory "examples/specs"
  payments <- walkAll "examples/native-payments"
  packages <- walkAll "examples/packages"
  -- Every staged document has its source at the repository root.
  documents <- filter (\f -> ".md" `isSuffixOf` f || f == "LICENSE") . sort <$> listDirectory "npm"
  let pairs = ("examples/specs/atoi_codec.lawspec", "npm/starter.lawspec") :
        [(d, "npm/" ++ d) | d <- documents] ++
        [("examples/specs/" ++ f, "npm/examples/specs/" ++ f) | f <- specs] ++
        [(f, "npm/" ++ f) | f <- payments ++ packages]
  forM_ pairs $ \(source, copy) -> do
    exists <- doesFileExist copy
    same <- if exists then (==) <$> B.readFile source <*> B.readFile copy else pure False
    unless same (die ("Stale npm copy: " ++ copy ++ " differs from " ++ source ++ "; run tools/wasm.sh"))
  where walkAll = walk (const True)

-- Directory entries are visited in sorted order; hidden, dunder and Cargo
-- target directories are build output, not sources.
walk :: (FilePath -> Bool) -> FilePath -> IO [FilePath]
walk select dir = do
  entries <- sort . filter keep <$> listDirectory dir
  concat <$> forM entries (\entry -> do
    let path = dir ++ "/" ++ entry
    isDirectory <- doesDirectoryExist path
    if isDirectory then walk select path
    else pure [path | select path])
  where keep name = not ("." `isPrefixOf` name || "__" `isPrefixOf` name || name == "target")

hex :: B.ByteString -> String
hex = concatMap (\w -> [intToDigit (fromIntegral w `div` 16), intToDigit (fromIntegral w `mod` 16)]) . B.unpack

-- The layout matches JSON.stringify(record, null, 2) from the former JavaScript
-- tool, so the recorded file is unchanged by the port.
render :: [FilePath] -> [(FilePath, String)] -> String
render sources digests = unlines
  [ "{"
  , "  \"version\": 1,"
  , "  \"compilerSources\": ["
  , intercalate ",\n" ["    " ++ json s | s <- sources]
  , "  ],"
  , "  \"digests\": {"
  , intercalate ",\n" ["    " ++ json file ++ ": " ++ json digest | (file, digest) <- digests]
  , "  }"
  , "}" ]
  where json s = "\"" ++ concatMap escape s ++ "\""
        escape '"' = "\\\""
        escape '\\' = "\\\\"
        escape c = [c]
