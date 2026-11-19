-- | Development checks for the LawSpec repository. Run from the repository root:
--
--   lawspec-dev boundaries          Core/backends never import syntax or inference
--   lawspec-dev integrity           npm/build.json matches sources and artifacts,
--                                   staged npm copies match their sources, and a
--                                   built host-effect core matches its record
--   lawspec-dev integrity --record  rewrite npm/build.json (tools/wasm.sh)
--   lawspec-dev dependencies --check  stack resolves wasm/cabal.project.freeze's versions
--   lawspec-dev native-check       packed native/source acceptance on this host
--   lawspec-dev ci [options]        the complete check; see dev/Ci.hs
--   lawspec-dev clean --artifacts [--keep-cache]
--                                   remove build output under .artifacts and,
--                                   without --keep-cache, recorded passes
--   lawspec-dev generate [--check]  generated JavaScript and runtimes; see dev/Generate.hs
--   lawspec-dev capability-receipts [--check]
--                                   the capability laws' proofs; see dev/CapabilityReceipts.hs
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
import CapabilityReceipts (capabilityReceiptsCommand)
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
import qualified LawSpec.Archive.Deflate as Deflate
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
    ["dependencies", "--check"] -> dependencyDrift
    ["canon-packages"] -> canonPackages False
    ["canon-packages", "--record"] -> canonPackages True
    ["native-check"] -> nativeCheck
    ["native-acceptance", "--package", receipt, "--out", output] -> nativeAcceptance receipt output
    "ci" : options -> ci options
    "clean" : options -> clean options
    "generate" : options -> generateCommand options
    "capability-receipts" : options -> capabilityReceiptsCommand options
    "version" : options -> versionCommand options
    "bump" : options -> bumpCommand options
    "docs" : options -> docsCommand options
    "canon" : options -> canonCommand options
    "bench" : options -> benchCommand options
    "email-vectors" : options -> emailVectorsCommand options
    "tax" : options -> taxCommand options
    _ -> die "usage: lawspec-dev boundaries | integrity [--record] | dependencies --check | native-check | native-acceptance --package <receipt.json> --out <new-directory> | ci [options] | clean --artifacts [--keep-cache] | generate [--check|--list] | capability-receipts [--check] | version [--check] | bump <x.y.z> | docs --out <dir> | docs --check | canon [arguments] | beam-vectors <file> | email-vectors [--check] <Address.pm> [corpus...] | bench <name> [--scale N] [--generate] [target...] | tax assess|pay [port]|audit"

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
  seen <- visitAll (\name -> S.member name forbidden || application name) "Core/backend" S.empty [(root, []) | root <- roots]
  putStrLn
    ( "Core and emitters: "
        ++ show (S.size seen)
        ++ " modules satisfy the syntax/inference boundary."
    )
  controller <- visitAll (`notElem` controllerModules) "Manifest/controller" S.empty [(root, []) | root <- controllerRoots]
  putStrLn ("Manifest/controller services: " ++ show (S.size controller) ++ " modules remain independent of the compiler.")
  -- The host-effect layer is shared by every host and by the application;
  -- it must not reach the compiler or the commands. ref:DEC-host-effect-abi
  host <- visitAll (`notElem` hostModules) "Host effect" S.empty [(root, []) | root <- hostModules]
  putStrLn ("Host effects: " ++ show (S.size host) ++ " modules remain independent of the compiler and commands.")
  where
    application name = any (`isPrefixOf` name) ["Host.", "App."]
    hostModules = ["Host.Effect", "Host.Policy", "Host.Codec", "Host.Base64", "Host.Path", "Host.Sandbox", "Host.Fake", "Host.Native", "Host.Conformance"]
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
          -- The native host interpreter is built only for native targets,
          -- from src-native.
          let file = "LawSpec" </> map (\c -> if c == '.' then '/' else c) name ++ ".hs"
          native <- doesFileExist ("src-native" </> file)
          source <- readFile ((if native then "src-native" else "src") </> file)
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
-- The host-effect core (lawspec-host-core, docs/reference/host-effects.md)
-- is fingerprinted too: its sources with the compiler's, and the module
-- tools/wasm-host-core.sh builds as "hostCore". That module is a build
-- output, not committed, so it is checked whenever it has been built here.
-- ref:DEC-host-effect-abi
-- | The native build (stack) must resolve every library the WebAssembly
-- build (wasm/cabal.project.freeze) pins to the same version, so that
-- lawspec-native renders what the core renders: a different megaparsec once
-- changed parse-error carets. GHC's boot packages follow each compiler and
-- are left out.
dependencyDrift :: IO ()
dependencyDrift = do
  native <- pairs . lines <$> readProcess "stack" ["--no-terminal", "ls", "dependencies"] ""
  boot <- words <$> readProcess "stack" ["--no-terminal", "exec", "--", "ghc-pkg", "list", "--global", "--simple-output", "--names-only"] ""
  freeze <- readFile "wasm/cabal.project.freeze"
  let pinned = [(name, takeWhile (/= ',') version) | (name, version) <- frozen freeze]
      drifted = [(name, have, want) | (name, want) <- nub pinned, name `notElem` boot, name `notElem` exempt, Just have <- [lookup name native], have /= want]
  case drifted of
    [] -> putStrLn "stack resolves every library wasm/cabal.project.freeze pins to the same version."
    _ ->
      die
        ( unlines
            ( "stack and wasm/cabal.project.freeze disagree; pin these in stack.yaml extra-deps:"
                : ["  " ++ name ++ ": stack " ++ have ++ ", freeze " ++ want | (name, have, want) <- drifted]
            )
        )
  where
    -- QuickCheck and random reach the build only through aeson's Arbitrary
    -- instances and the test suite (hspec-core needs QuickCheck < 2.19); no
    -- compiler, application or host module imports either, so they shape no
    -- output.
    exempt = ["QuickCheck", "random"]
    pairs rows = [(name, version) | row <- rows, [name, version] <- [words row]]
    frozen text = [(name, version) | line <- lines text, Just rest <- [stripPrefix "any." (dropWhile (== ' ') (dropPrefix "constraints:" (dropWhile (== ' ') line)))], (name, version') <- [break (== ' ') rest], Just version <- [stripPrefix " ==" version']]
    dropPrefix prefix text = maybe text id (stripPrefix prefix text)

integrity :: Bool -> IO ()
integrity record = do
  haskell <- walk (".hs" `isSuffixOf`) "src"
  wasmApp <- walk (".hs" `isSuffixOf`) "wasm/app"
  hostCoreSources <- walk (\p -> any (`isSuffixOf` p) [".hs", ".c"]) "wasm/host"
  runtimes <- walk runtimeFile "runtime"
  componentArtifacts <- walk (const True) "npm/host-component"
  let sources =
        sort
          ( haskell
              ++ wasmApp
              ++ hostCoreSources
              ++ runtimes
              ++ [ "dev/Gen/Embed.hs",
                   "package.yaml",
                   "lawspec.cabal",
                   "stack.yaml",
                   "stack.yaml.lock",
                   "tools/wasm-host-core.sh",
                   "wasm/cabal.project",
                   "wasm/cabal.project.freeze",
                   "wasm/lawspec-wasm.cabal",
                   "vendor/unicode/17.0.0/CaseFolding.txt",
                   "vendor/unicode/LICENSE.txt"
                 ]
          )
      artifacts = ["npm/core.wasm", "npm/core_jsffi.js", "npm/api.mjs", "npm/index.d.ts", "npm/host-codecs.mjs", "npm/host-launcher.mjs"] ++ sort componentArtifacts
  coreBuilt <- doesFileExist "npm/core.wasm"
  unless coreBuilt (die "npm/core.wasm is not built here (git ignores it); run tools/wasm.sh")
  digests <- forM (sources ++ artifacts) $ \file -> (,) file . hex . SHA256.hash <$> B.readFile file
  hostCoreBuilt <- doesFileExist hostCoreFile
  hostCore <-
    if hostCoreBuilt
      then Just . hex . SHA256.hash <$> B.readFile hostCoreFile
      else pure Nothing
  if record
    then case hostCore of
      Just digest -> do
        writeFile "npm/build.json" (render sources digests digest)
        release <- releaseVersion
        writeFile goCorePin (renderGoCorePin release digest)
      Nothing -> die ("No " ++ hostCoreFile ++ " to record; run tools/wasm-host-core.sh")
    else do
      stagedCopies
      recorded <- readFile "npm/build.json"
      let recordedHostCore = recordedDigest "hostCore" recorded
      case (hostCore, recordedHostCore) of
        (_, Nothing) -> die "npm/build.json records no hostCore; run tools/wasm.sh"
        (Just actual, Just expected)
          | actual /= expected ->
              die ("Stale build artifact: " ++ hostCoreFile ++ " differs from npm/build.json; run tools/wasm.sh")
        _ -> pure ()
      forM_ recordedHostCore $ \expected -> do
        release <- releaseVersion
        pin <- readFile goCorePin
        unless (pin == renderGoCorePin release expected) $
          die ("Stale Go core pin: " ++ goCorePin ++ " does not record npm/build.json's hostCore for " ++ release ++ "; run tools/wasm.sh")
      unless (Just recorded == fmap (render sources digests) recordedHostCore) $ do
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
      learnArchive
      canonPackages False
      putStrLn "WASM, generated API, and compiler source fingerprints match."
      putStrLn $
        if hostCoreBuilt
          then "The host-effect core matches its fingerprint."
          else "The host-effect core is not built here (" ++ hostCoreFile ++ "); only its sources were checked."
  where
    hostCoreFile = "npm/host-core.wasm"
    -- The Go host downloads the core this pin names (hosts/go/internal/core).
    -- ref:DEC-go-core-download
    goCorePin = "hosts/go/internal/core/pin.go"
    releaseVersion = do
      manifest <- readFile "package.yaml"
      case [rest | line <- lines manifest, Just rest <- [stripPrefix "version: " line]] of
        value : _ -> length manifest `seq` pure value
        [] -> die "package.yaml has no version"
    -- npm/core.wasm.gz, which lawspec learn serves, is ignored by git and
    -- written by tools/learn-compiler.mjs; when present it must hold exactly
    -- npm/core.wasm, so a stale copy is never packed.
    learnArchive = do
      present <- doesFileExist "npm/core.wasm.gz"
      if not present
        then putStrLn "npm/core.wasm.gz is not built here; make package writes it."
        else do
          archive <- B.readFile "npm/core.wasm.gz"
          core <- B.readFile "npm/core.wasm"
          case Deflate.gunzip archive of
            Right contents | contents == core -> putStrLn "npm/core.wasm.gz holds npm/core.wasm."
            _ -> die "Stale build artifact: npm/core.wasm.gz does not hold npm/core.wasm; run node tools/learn-compiler.mjs"
    recordedDigest key text =
      case [rest | line <- lines text, Just rest <- [stripPrefix ("  \"" ++ key ++ "\": \"") line]] of
        rest : _ -> Just (takeWhile (/= '"') rest)
        [] -> Nothing
    runtimeFile p =
      any (`isSuffixOf` p) [".rs", ".py", ".pl", ".mjs", ".ts", ".java", ".kt", ".scala", ".go", ".hs", ".erl", ".ex", ".gleam", ".groovy", ".clj"]
        || any (`isSuffixOf` p) ["Cargo.toml", "Cargo.lock"]
    quoted s = "\"" ++ s ++ "\""
    isInfixOf' needle haystack = any (needle `isPrefixOf`) (tails' haystack)
    tails' [] = [[]]
    tails' s@(_ : rest) = s : tails' rest

-- | hosts/go/internal/core/pin.go: the release and the SHA-256 of the
-- host-effect core (npm/build.json's hostCore) the Go host downloads as
-- @goforgedev/core and checks. ref:DEC-go-core-download
renderGoCorePin :: String -> String -> String
renderGoCorePin release digest =
  unlines
    [ "// Code generated by lawspec-dev integrity --record from package.yaml and npm/build.json. DO NOT EDIT.",
      "",
      "package core",
      "",
      "// Version is the LawSpec release whose @goforgedev/core package holds the core.",
      "const Version = \"" ++ release ++ "\"",
      "",
      "// SHA256 is the core's (host-core.wasm's) SHA-256, in lowercase hexadecimal.",
      "const SHA256 = \"" ++ digest ++ "\""
    ]

-- | The @goforgedev/canon-<platform> tarballs tools/package-canon.sh packs
-- into .artifacts/canon-npm, against the digests the core records for the
-- Go host's download (src/LawSpec/App/CanonPackages.hs). Checking, each
-- tarball present must match its recorded digest for this version; with
-- --record, the present tarballs' digests are written (a version change
-- clears the others, which then download nothing until recorded).
-- ref:DEC-native-canon
canonPackages :: Bool -> IO ()
canonPackages record = do
  release <- packageVersion
  source <- readFile pinsFile
  let recordedVersion = case [takeWhile (/= '"') rest | line <- lines source, Just rest <- [stripPrefix "canonPackagesVersion = \"" line]] of
        value : _ -> value
        [] -> ""
      recorded platform = case [takeWhile (/= '"') rest | line <- lines source, Just rest <- [stripPrefix ("  [ (\"" ++ platform ++ "\", \"") line <|> stripPrefix ("    (\"" ++ platform ++ "\", \"") line]] of
        value : _ -> value
        [] -> ""
  packed <- forM platforms $ \platform -> do
    let file = ".artifacts/canon-npm/goforgedev-canon-" ++ platform ++ "-" ++ release ++ ".tgz"
    present <- doesFileExist file
    digest <- if present then Just . hex . SHA256.hash <$> B.readFile file else pure Nothing
    pure (platform, file, digest)
  if record
    then do
      let kept platform = if recordedVersion == release then recorded platform else ""
          digests = [(platform, maybe (kept platform) id digest) | (platform, _, digest) <- packed]
      length source `seq` writeFile pinsFile (renderPins source release digests)
      forM_ packed $ \(platform, file, digest) ->
        putStrLn (platform ++ ": " ++ maybe ("not packed here (" ++ file ++ "); " ++ (if null (kept platform) then "none recorded" else "kept")) ("recorded " ++) digest)
    else forM_ packed $ \(platform, file, digest) -> case digest of
      Nothing -> pure ()
      Just actual
        | recordedVersion /= release || recorded platform /= actual ->
            die ("Stale Canon package digest: " ++ file ++ " is not what " ++ pinsFile ++ " records; run lawspec-dev canon-packages --record")
        | otherwise -> putStrLn (file ++ " matches its recorded digest.")
  where
    pinsFile = "src/LawSpec/App/CanonPackages.hs"
    platforms = ["darwin-arm64", "darwin-x64", "linux-arm64", "linux-x64"]
    packageVersion = do
      manifest <- readFile "package.yaml"
      case [rest | line <- lines manifest, Just rest <- [stripPrefix "version: " line]] of
        value : _ -> pure value
        [] -> die "package.yaml has no version"
    a <|> b = maybe b Just a
    renderPins source release digests =
      let (header, _) = breakOn "canonPackagesVersion ::" source
       in header
            ++ unlines
              ( [ "canonPackagesVersion :: String",
                  "canonPackagesVersion = \"" ++ release ++ "\"",
                  "",
                  "-- | Each platform's tarball digest, in lowercase hexadecimal.",
                  "canonPackageDigests :: [(String, String)]",
                  "canonPackageDigests ="
                ]
                  ++ zipWith (\i (platform, digest) -> (if i == (0 :: Int) then "  [ " else "    ") ++ "(\"" ++ platform ++ "\", \"" ++ digest ++ "\")" ++ (if i == length digests - 1 then "" else ",")) [0 ..] digests
                  ++ ["  ]"]
              )
    breakOn needle text = go [] text
      where
        go acc rest
          | needle `isPrefixOf` rest = (reverse acc, rest)
          | otherwise = case rest of
              [] -> (reverse acc, [])
              c : more -> go (c : acc) more

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
render :: [FilePath] -> [(FilePath, String)] -> String -> String
render sources digests hostCore =
  unlines
    [ "{",
      "  \"version\": 1,",
      "  \"compilerSources\": [",
      intercalate ",\n" ["    " ++ json s | s <- sources],
      "  ],",
      "  \"digests\": {",
      intercalate ",\n" ["    " ++ json file ++ ": " ++ json digest | (file, digest) <- digests],
      "  },",
      "  \"hostCore\": " ++ json hostCore,
      "}"
    ]
  where
    json s = "\"" ++ concatMap escape s ++ "\""
    escape '"' = "\\\""
    escape '\\' = "\\\\"
    escape c = [c]
