-- | Development checks for the LawSpec repository. Run from the repository root:
--
--   lawspec-dev boundaries          Core/backends never import syntax or inference
--   lawspec-dev integrity           npm/build.json matches sources and artifacts,
--                                   and staged npm copies match their sources
--   lawspec-dev integrity --record  rewrite npm/build.json (tools/wasm.sh)
--   lawspec-dev native-check       packed native/source acceptance on this host
--   lawspec-dev ci [options]        the complete check; see dev/Ci.hs
--   lawspec-dev clean --artifacts [--keep-cache]
--                                   remove build output under .artifacts and,
--                                   without --keep-cache, recorded passes
--   lawspec-dev generate [--check]  generated JavaScript and runtimes; see dev/Generate.hs
--   lawspec-dev version [--check]   the release version
--   lawspec-dev bump <x.y.z>        set the release version everywhere
--   lawspec-dev docs [--check]      the documentation site; see dev/Docs.hs
--   lawspec-dev canon [arguments]   canon over the repository; see dev/Canon.hs
--   lawspec-dev beam-vectors <file> scalar vectors from Core for BEAM conformance
--   lawspec-dev email-vectors <Address.pm>
--                                   the email format's vectors; see dev/EmailVectors.hs
--   lawspec-dev bench <name> [...]  benchmarks of generated code; see dev/Bench.hs
--   lawspec-dev tax <verb> [...]    Rice's Tax over the repository; see dev/Canon.hs
module Main (main) where

import BeamVectors (writeVectors)
import Bench (benchCommand)
import Canon (canonCommand, taxCommand)
import Ci (ci, clean)
import Control.Exception (bracket, bracketOnError)
import Control.Monad (forM, forM_, unless, when)
import qualified Crypto.Hash.SHA256 as SHA256
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Types as Aeson
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.Char (intToDigit, isAsciiLower, isAsciiUpper, isDigit)
import Data.List (intercalate, isPrefixOf, isSuffixOf, nub, sort, stripPrefix)
import Data.Maybe (mapMaybe)
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Docs (docsCommand)
import EmailVectors (emailVectorsCommand)
import Generate (bumpCommand, generateCommand, versionCommand)
import System.Directory (copyFile, createDirectory, createDirectoryIfMissing, doesDirectoryExist, doesFileExist, doesPathExist, getTemporaryDirectory, listDirectory, makeAbsolute, pathIsSymbolicLink, removePathForcibly, renameDirectory)
import System.Environment (getArgs)
import System.Exit (die)
import System.FilePath (dropTrailingPathSeparator, normalise, takeDirectory, (</>))
import System.IO.Error (catchIOError)
import System.Posix.Files (setFileMode)
import System.Posix.Temp (mkdtemp)
import System.Process (callProcess, readProcess)

main :: IO ()
main =
  getArgs >>= \case
    ["beam-vectors", path] -> writeVectors path
    ["boundaries"] -> boundaries
    ["integrity"] -> integrity False
    ["integrity", "--record"] -> integrity True
    ["native-check"] -> nativeCheck
    ["native-acceptance", "--package", receipt, "--out", output] -> nativeAcceptance receipt output
    "ci" : options -> ci options
    "clean" : options -> clean options
    "generate" : options -> generateCommand options
    "version" : options -> versionCommand options
    "bump" : options -> bumpCommand options
    "docs" : options -> docsCommand options
    "canon" : options -> canonCommand options
    "bench" : options -> benchCommand options
    "email-vectors" : options -> emailVectorsCommand options
    "tax" : options -> taxCommand options
    _ -> die "usage: lawspec-dev boundaries | integrity [--record] | native-check | native-acceptance --package <receipt.json> --out <new-directory> | ci [options] | clean --artifacts [--keep-cache] | generate [--check|--list] | version [--check] | bump <x.y.z> | docs --out <dir> | docs --check | canon [arguments] | beam-vectors <file> | email-vectors [--check] <Address.pm> [corpus...] | bench <name> [--scale N] [--generate] [target...] | tax assess|pay [port]|audit"

-- | Exercise the actual pinned distribution on the current host, uncached.
-- Keep assembly controls, a fresh npm archive and both runtime modes together.
-- ref:DEC-local-ci-only ref:DEC-node-native-acceptance-bundle
nativeCheck :: IO ()
nativeCheck = do
  callProcess "node" ["--test", "component/test/acceptance-bundle.test.mjs"]
  parent <- getTemporaryDirectory
  bracket (mkdtemp (parent </> "lawspec-native-check-")) removePathForcibly $ \directory -> do
    packed <- readProcess "npm" ["pack", "./npm", "--ignore-scripts", "--json", "--pack-destination", directory] ""
    receipts <- either die pure (Aeson.eitherDecodeStrict (TE.encodeUtf8 (T.pack packed)) :: Either String [Aeson.Value])
    receipt <- case receipts of
      [value] -> pure value
      _ -> die "native-check requires exactly one npm package receipt"
    let record = directory </> "application-package.json"
        bundle = directory </> "bundle"
    BL.writeFile record (Aeson.encode receipt)
    nativeAcceptance record bundle
    callProcess "node" [bundle </> "run.mjs"]

-- | Assemble the toolchain-free native acceptance bundle from pinned packages.
-- Validate the copied bytes before making the complete directory visible.
-- ref:DEC-node-native-acceptance-bundle
nativeAcceptance :: FilePath -> FilePath -> IO ()
nativeAcceptance receipt output = do
  destination <- normalise . dropTrailingPathSeparator <$> makeAbsolute output
  let staging = destination ++ ".staging"
      platforms = ["darwin-arm64", "darwin-x64", "linux-arm64", "linux-x64"]
      sdkReceipt = "component/sdk-packages.json"
      nativeReceipt = "component/native-packages.json"
  forM_ [destination, staging] $ \directory -> do
    exists <- doesPathExist directory
    linked <- catchIOError (pathIsSymbolicLink directory) (const (pure False))
    when (exists || linked) (die ("Acceptance output already exists: " ++ directory))
  sdkBytes <- B.readFile sdkReceipt
  nativeBytes <- B.readFile nativeReceipt
  applicationBytes <- B.readFile receipt
  sdk <- parseAcceptance sdkBytes $ Aeson.withObject "SDK packages" $ \object -> do
    runtime <- object Aeson..: "runtime" >>= archiveRecord True
    targets <- object Aeson..: "platforms"
    helpers <- forM platforms $ \platform -> targets Aeson..: platform >>= archiveRecord True
    pure (runtime : helpers)
  natives <- parseAcceptance nativeBytes $ Aeson.withObject "native packages" $ \object ->
    forM platforms $ \platform -> object Aeson..: platform >>= archiveRecord False
  application <- parseAcceptance applicationBytes $ Aeson.withObject "single npm pack receipt" $ \object ->
    (,) <$> object Aeson..: "filename" <*> object Aeson..: "integrity"
  let archives =
        [("component/vendor" </> file, file, integrity') | (file, integrity') <- sdk ++ natives]
          ++ [(takeDirectory receipt </> fst application, fst application, snd application)]
      names = [file | (_, file, _) <- archives]
  unless (length names == length (nub names)) (die "Duplicate acceptance archive names")
  forM_ names $ \file ->
    unless (safeArchiveName file) (die ("Invalid acceptance archive filename: " ++ file))
  createDirectoryIfMissing True (takeDirectory destination)
  bracketOnError
    (createDirectory staging >> pure staging)
    removePathForcibly
    ( \directory -> do
        setFileMode directory 0o700
        let vendor = directory </> "component/vendor"
        createDirectoryIfMissing True vendor
        createDirectoryIfMissing True (directory </> "component/test")
        forM_ archives $ \(source, file, expected) -> do
          linked <- pathIsSymbolicLink source
          when linked (die ("Acceptance archive must not be a symlink: " ++ source))
          let target = vendor </> file
          copyFile source target
          actual <- archiveIntegrity target
          unless (actual == expected) (die ("Acceptance archive integrity mismatch: " ++ file))
        B.writeFile (directory </> sdkReceipt) sdkBytes
        B.writeFile (directory </> nativeReceipt) nativeBytes
        B.writeFile (vendor </> "application-package.json") applicationBytes
        copyFile "component/test/package.test.mjs" (directory </> "component/test/package.test.mjs")
        copyFile "component/test/native-acceptance-runner.mjs" (directory </> "run.mjs")
        copyFile "component/acceptance/README.txt" (directory </> "README.txt")
        renameDirectory directory destination
    )
  putStrLn ("Verified native acceptance bundle: " ++ destination ++ "; platform execution is still required.")

-- | Parse a receipt snapshot without rereading mutable metadata during assembly.
-- ref:DEC-node-native-acceptance-bundle
parseAcceptance :: B.ByteString -> (Aeson.Value -> Aeson.Parser a) -> IO a
parseAcceptance bytes parser =
  either die pure (Aeson.eitherDecodeStrict bytes >>= Aeson.parseEither parser)

-- | SDK archives use content-addressed local names; native records already do.
-- ref:DEC-node-native-acceptance-bundle
archiveRecord :: Bool -> Aeson.Value -> Aeson.Parser (FilePath, String)
archiveRecord sdk = Aeson.withObject "archive receipt" $ \object -> do
  file <- object Aeson..: "file"
  integrity' <- object Aeson..: "integrity"
  unless (safeArchiveName file) (fail "Invalid acceptance archive filename")
  name <-
    if sdk
      then do
        shasum <- object Aeson..: "shasum"
        unless (length shasum == 40 && all (`elem` ("0123456789abcdef" :: String)) shasum) (fail "Invalid SDK archive shasum")
        pure (take (length file - 4) file ++ "-" ++ take 12 shasum ++ ".tgz")
      else pure file
  pure (name, integrity')

-- | Archive receipts name files only, never paths or shell arguments.
-- ref:DEC-node-native-acceptance-bundle
safeArchiveName :: FilePath -> Bool
safeArchiveName file =
  length file > 4
    && ".tgz" `isSuffixOf` file
    && all (\c -> isAsciiLower c || isAsciiUpper c || isDigit c || c `elem` ("._-" :: String)) file

-- | Use Node's established streaming crypto provider for npm's SHA-512 SRI.
-- Haskell owns receipt validation; no archive is extracted or executed here.
-- ref:DEC-node-native-acceptance-bundle
archiveIntegrity :: FilePath -> IO String
archiveIntegrity file = do
  result <-
    readProcess
      "node"
      [ "--input-type=module",
        "-e",
        "import {createReadStream} from 'node:fs'; import {createHash} from 'node:crypto'; const h=createHash('sha512'); for await (const b of createReadStream(process.argv[1])) h.update(b); console.log('sha512-'+h.digest('base64'));",
        file
      ]
      ""
  pure (takeWhile (/= '\n') result)

-- | Follow transitive local imports, so a convenience module cannot hide
-- syntax or inference behind Core, the testing plan, or an emitter.
boundaries :: IO ()
boundaries = do
  seen <- visitAll (`S.member` forbidden) "Core/backend" S.empty [(root, []) | root <- roots]
  putStrLn
    ( "Core and emitters: "
        ++ show (S.size seen)
        ++ " modules satisfy the syntax/inference boundary."
    )
  controller <- visitAll (`notElem` controllerModules) "Manifest/controller" S.empty [(root, []) | root <- controllerRoots]
  putStrLn ("Manifest/controller services: " ++ show (S.size controller) ++ " modules remain independent of the compiler.")
  where
    forbidden =
      S.fromList
        [ "Model",
          "Parser",
          "Compile",
          "Inference",
          "Elaboration",
          "Frontend",
          "Refinement",
          "Domain",
          "Eval",
          "Public",
          "Api"
        ]
    roots =
      [ "Core",
        "Core.Validate",
        "Core.Total",
        "Core.Definitions",
        "Core.Eval",
        "Core.Payload",
        "Core.Semantics",
        "Testing",
        "Backend",
        "CoreEmit",
        "JavaData",
        "RustEmit",
        "CoreScalarEmit",
        "CoreNativeScalarEmit",
        "KotlinData",
        "Core.DomainEvidence",
        "Core.Smt",
        "Prolog.Emit"
      ]
    controllerRoots = ["Manifest.Types", "Manifest.Decode", "Service.Manifest", "Version"]
    controllerModules = controllerRoots ++ ["Manifest.EDN", "Targets", "ActorRuntime"]
    visitAll _ _ seen [] = pure seen
    visitAll rejected boundary seen ((name, trail) : rest) = do
      when
        (rejected name)
        (die (boundary ++ " boundary violation: " ++ intercalate " -> " (reverse (name : trail))))
      if name `S.member` seen
        then visitAll rejected boundary seen rest
        else do
          source <- readFile ("src/LawSpec" </> map (\c -> if c == '.' then '/' else c) name ++ ".hs")
          let imports = mapMaybe localImport (lines source)
          visitAll rejected boundary (S.insert name seen) ([(i, name : trail) | i <- imports] ++ rest)
    localImport line = do
      rest <- stripPrefix "import " line
      let unqualified = maybe rest dropSpaces (stripPrefix "qualified " (dropSpaces rest))
      module' <- stripPrefix "LawSpec." (dropSpaces unqualified)
      pure (takeWhile (\c -> c `notElem` (" (" :: String)) module')
    dropSpaces = dropWhile (== ' ')

-- | Every compiler source and generated npm artifact is fingerprinted, so a
-- published package can never pair a WASM build with different sources.
integrity :: Bool -> IO ()
integrity record = do
  haskell <- walk (".hs" `isSuffixOf`) "src"
  wasmApp <- walk (".hs" `isSuffixOf`) "wasm/app"
  runtimes <- walk runtimeFile "runtime"
  componentArtifacts <- walk (const True) "npm/host-component"
  let sources =
        sort
          ( haskell
              ++ wasmApp
              ++ runtimes
              ++ [ "dev/Gen/Embed.hs",
                   "package.yaml",
                   "lawspec.cabal",
                   "stack.yaml",
                   "stack.yaml.lock",
                   "wasm/cabal.project",
                   "wasm/cabal.project.freeze",
                   "wasm/lawspec-wasm.cabal",
                   "vendor/unicode/17.0.0/CaseFolding.txt",
                   "vendor/unicode/LICENSE.txt"
                 ]
          )
      artifacts = ["npm/core.wasm", "npm/core_jsffi.js", "npm/api.mjs", "npm/index.d.ts", "npm/host-codecs.mjs", "npm/host-launcher.mjs"] ++ sort componentArtifacts
  digests <- forM (sources ++ artifacts) $ \file -> (,) file . hex . SHA256.hash <$> B.readFile file
  if record
    then writeFile "npm/build.json" (render sources digests)
    else do
      stagedCopies
      recorded <- readFile "npm/build.json"
      unless (recorded == render sources digests) $ do
        let stale =
              [ file
              | (file, digest) <- digests,
                not
                  ( quoted digest `isInfixOf'` recorded
                      && quoted file `isInfixOf'` recorded
                  )
              ]
        die
          ( case stale of
              file : _ -> "Stale build artifact/source: " ++ file ++ "; run tools/wasm.sh"
              [] -> "Compiler source set changed; run tools/wasm.sh"
          )
      putStrLn "WASM, generated API, and compiler source fingerprints match."
  where
    runtimeFile p =
      any (`isSuffixOf` p) [".rs", ".py", ".pl", ".mjs", ".ts", ".java", ".kt", ".scala", ".go", ".hs", ".erl", ".ex", ".gleam", ".groovy", ".clj"]
        || any (`isSuffixOf` p) ["Cargo.toml", "Cargo.lock"]
    quoted s = "\"" ++ s ++ "\""
    isInfixOf' needle haystack = any (needle `isPrefixOf`) (tails' haystack)
    tails' [] = [[]]
    tails' s@(_ : rest) = s : tails' rest

-- | tools/wasm.sh stages the license and examples into npm/. They stay
-- committed because CI jobs without Haskell pack and run the package, so every
-- staged copy must be byte-identical to its source. README.md and CHANGELOG.md
-- are copied by npm's prepack instead and not committed.
stagedCopies :: IO ()
stagedCopies = do
  specs <- filter (".lawspec" `isSuffixOf`) . sort <$> listDirectory "examples/specs"
  payments <- walkAll "examples/native-payments"
  canonical <- walkAll "examples/rc1"
  packages <- walkAll "examples/packages"
  -- The license is staged; README.md and CHANGELOG.md are copied afresh by
  -- npm's prepack on every pack, so a copy left from an earlier pack is not
  -- checked. ref:DEC-npm-documents-copied
  let documents = ["LICENSE"]
  let pairs =
        ("examples/specs/atoi_codec.lawspec", "npm/starter.lawspec")
          : ("vendor/unicode/LICENSE.txt", "npm/UNICODE-LICENSE.txt")
          : ("vendor/unicode/NORMALIZATION-LICENSES.txt", "npm/NORMALIZATION-LICENSES.txt")
          : [(d, "npm/" ++ d) | d <- documents]
          ++ [("examples/specs/" ++ f, "npm/examples/specs/" ++ f) | f <- specs]
          ++ [("examples/rc1-authoring.lawspec", "npm/examples/rc1-authoring.lawspec")]
          ++ [(f, "npm/" ++ f) | f <- payments ++ canonical ++ packages]
  forM_ pairs $ \(source, copy) -> do
    exists <- doesFileExist copy
    same <- if exists then (==) <$> B.readFile source <*> B.readFile copy else pure False
    unless same (die ("Stale npm copy: " ++ copy ++ " differs from " ++ source ++ "; run tools/wasm.sh"))
  where
    walkAll = walk (const True)

-- | Directory entries are visited in sorted order; hidden, dunder and Cargo
-- target directories are build output, not sources.
walk :: (FilePath -> Bool) -> FilePath -> IO [FilePath]
walk select dir = do
  entries <- sort . filter keep <$> listDirectory dir
  concat
    <$> forM
      entries
      ( \entry -> do
          let path = dir ++ "/" ++ entry
          isDirectory <- doesDirectoryExist path
          if isDirectory
            then walk select path
            else pure [path | select path]
      )
  where
    keep name = not ("." `isPrefixOf` name || "__" `isPrefixOf` name || name == "target")

hex :: B.ByteString -> String
hex = concatMap (\w -> [intToDigit (fromIntegral w `div` 16), intToDigit (fromIntegral w `mod` 16)]) . B.unpack

-- | The layout matches JSON.stringify(record, null, 2) from the former JavaScript
-- tool, so the recorded file is unchanged by the port.
render :: [FilePath] -> [(FilePath, String)] -> String
render sources digests =
  unlines
    [ "{",
      "  \"version\": 1,",
      "  \"compilerSources\": [",
      intercalate ",\n" ["    " ++ json s | s <- sources],
      "  ],",
      "  \"digests\": {",
      intercalate ",\n" ["    " ++ json file ++ ": " ++ json digest | (file, digest) <- digests],
      "  }",
      "}"
    ]
  where
    json s = "\"" ++ concatMap escape s ++ "\""
    escape '"' = "\\\""
    escape '\\' = "\\\\"
    escape c = [c]
