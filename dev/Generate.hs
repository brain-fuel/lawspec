{-# LANGUAGE NoOverloadedStrings #-}
-- | Every JavaScript file of the repository, and the embedded runtime sources,
-- are generated here from templates/ and from facts Haskell owns: the version
-- (package.yaml), the targets, scaffolds, test commands and setup advice
-- (LawSpec.Scaffold) and the public API (Gen.Api).
--
--   lawspec-dev generate            write every output
--   lawspec-dev generate --check    fail if any output differs from its sources
--   lawspec-dev generate --list     print the outputs
--   lawspec-dev version [--check]   print the version; --check that every
--                                   versioned file agrees with package.yaml
--   lawspec-dev bump <x.y.z>        set the version everywhere, then generate
--
-- templates/<path> produces <path>. Outputs other than JSON carry a header
-- naming their template; an executable template produces an executable file.
module Generate (generateCommand, versionCommand, bumpCommand, currentVersion) where

import Control.Monad (forM, forM_, unless, when)
import Data.Char (isDigit)
import Data.List (intercalate, isPrefixOf, isSuffixOf, nub, sort, sortOn, (\\))
import System.Directory
import System.Exit (die, exitFailure)
import System.FilePath ((</>), takeDirectory, takeExtension)
import System.IO (readFile')
import System.Process (readProcessWithExitCode)
import Gen.Api (apiSources)
import Gen.Embed (embedRuntimes)
import Gen.Json
import Gen.Template
import LawSpec.Code.Doc (Layout(..))
import LawSpec.Scaffold (scaffoldFiles, scaffoldTargets, setupAdvice, testCommand)

data Output = Output { outputPath :: FilePath, outputContent :: String, outputExecutable :: Bool }

generateCommand :: [String] -> IO ()
generateCommand args = do
  outputs <- planOutputs
  case args of
    [] -> do
      forM_ outputs $ \o -> do
        createDirectoryIfMissing True (takeDirectory (outputPath o))
        current <- readIfExists (outputPath o)
        when (current /= Just (outputContent o)) (writeFile (outputPath o) (outputContent o))
        setExecutable (outputPath o) (outputExecutable o)
      putStrLn ("Generated " ++ show (length outputs) ++ " files.")
    ["--check"] -> do
      stale <- fmap concat $ forM outputs $ \o -> do
        current <- readIfExists (outputPath o)
        executable <- maybe (pure False) (const (executableFile (outputPath o))) current
        pure [outputPath o | current /= Just (outputContent o) || executable /= outputExecutable o]
      unless (null stale) $ die ("Stale generated files (run lawspec-dev generate):\n  " ++ intercalate "\n  " stale)
      stray <- strayScripts (map outputPath outputs)
      unless (null stray) $ die ("JavaScript not generated from templates/ (move it there, or list it in dev/Generate.hs):\n  " ++ intercalate "\n  " stray)
      putStrLn ("All " ++ show (length outputs) ++ " generated files match their templates and facts.")
    ["--list"] -> mapM_ (putStrLn . outputPath) outputs
    _ -> die "usage: lawspec-dev generate [--check | --list]"

planOutputs :: IO [Output]
planOutputs = do
  version <- currentVersion
  templates <- walkFiles "templates"
  partials <- forM (filter ("templates/partials/" `isPrefixOf`) templates) $ \file -> do
    source <- readFile' file
    pure ("partial-" ++ takeWhile (/= '.') (drop (length "templates/partials/") file), Block (lines source))
  -- The site is built by lawspec-dev docs; partials are only included.
  let site = filter (\t -> any (`isPrefixOf` t) ["templates/site/", "templates/partials/"]) templates
      fills = factFills version ++ partials
  rendered <- forM (templates \\ site) $ \template -> do
    source <- readFile' template
    executable <- executableFile template
    let target = drop (length "templates/") template
    (content, used) <- either die pure (fillTemplate template fills source)
    pure (Output target (withHeader template target content) executable, used)
  let used = nub (concatMap snd rendered)
      unused = map fst fills \\ used
  unless (null unused) (die ("Facts no template uses: " ++ unwords unused))
  let api = apiSources (Pretty 80)
      wide = [name | (name, content) <- api, any ((> 80) . length) (lines content)]
  unless (null wide) (die ("Generated API lines exceed 80 columns in: " ++ unwords wide))
  runtimes <- embedRuntimes
  let whole = [ Output "src/LawSpec/RuntimeSources.hs" runtimes False ] ++
        [ Output ("npm" </> name) content False | (name, content) <- api ]
  pure (sortOn outputPath (whole ++ map fst rendered))

-- | Every script in the repository is a generated output, a template, or one of
-- these: code users own (acceptance adapters, examples and fixtures), the
-- runtimes embedded in the compiler, and GHC's post-linker output.
strayScripts :: [FilePath] -> IO [FilePath]
strayScripts outputs = do
  (_, listing, _) <- readProcessWithExitCode "git" ["ls-files", "--cached", "--others", "--exclude-standard"] ""
  let scripts = [f | f <- lines listing, any (`isSuffixOf` f) [".mjs", ".js", ".cjs", ".ts"]]
      exempt f = any (`isPrefixOf` f) ["templates/", "runtime/", "acceptance/", "examples/", "npm/examples/", "test/fixtures/"]
        || f == "npm/core_jsffi.js"
  exists <- mapM doesFileExist scripts
  pure [f | (f, True) <- zip scripts exists, not (exempt f), f `notElem` outputs]

-- | JSON cannot carry a comment; the registry and --check cover it instead.
withHeader :: FilePath -> FilePath -> String -> String
withHeader template target content
  | takeExtension target `elem` [".json", ".html", ".md"] = content
  | otherwise = case lines content of
      first : rest | "#!" `isPrefixOf` first -> unlines (first : header : rest)
      _ -> header ++ "\n" ++ content
  where header = "// Generated from " ++ template ++ " by lawspec-dev generate. Do not edit."

-- | Values Haskell owns, as JavaScript source text.
factFills :: String -> [(String, Fill)]
factFills version =
  [ ("version", Inline (jsonString version))
  , ("targets", Inline (json (Array (map String scaffoldTargets))))
  , ("commands", Inline (json (Object [(t, String c) | t <- scaffoldTargets, Just c <- [testCommand t]])))
  , ("setup", Inline (json (Object [(t, String s) | t <- scaffoldTargets, Just s <- [setupAdvice t]])))
  , ("scaffolds", Inline (json (Object
      [ (t, Object [(layout, Object [(path, String content) | (path, content) <- files]) | (layout, minify) <- [("readable", False), ("compact", True)], Right files <- [scaffoldFiles minify t]])
      | t <- scaffoldTargets ])))
  , ("package-files", Inline (json (Array (map String shippedFiles))))
  , ("package-documents", Inline (json (Array [String f | f <- shippedFiles, ".md" `isSuffixOf` f || f == "LICENSE"])))
  , ("copy-documents", Inline (jsonString (unwords ("cp" : map ("../" ++) copiedDocuments ++ ["."]))))
  , ("hpack-version", Inline (jsonString "0.38.1")) ]

-- | What the npm package contains, beside its code.
shippedFiles :: [String]
shippedFiles = ["*.mjs", "*.json", "index.d.ts", "bin", "core.wasm", "core_jsffi.js"] ++ copiedDocuments ++ ["LICENSE", "starter.lawspec", "examples"]

-- | The root documents the package ships. Each has one home, the repository
-- root: npm's prepack copies them into npm/, where git ignores them.
copiedDocuments :: [String]
copiedDocuments = ["README.md", "CHANGELOG.md"]

currentVersion :: IO String
currentVersion = do
  manifest <- readFile' "package.yaml"
  case [drop (length "version: ") l | l <- lines manifest, "version: " `isPrefixOf` l] of
    v : _ -> pure v
    [] -> die "package.yaml has no version"

-- | Files that state the version outside generated outputs.
versionedFiles :: [(FilePath, String -> String -> String -> String)]
versionedFiles =
  [ ("package.yaml", lineValue "version: ")
  , ("lawspec.cabal", lineValue "version:        ")
  , ("wasm/lawspec-wasm.cabal", lineValue "version: ")
  , ("runtime/rust/Cargo.toml", cargo "[package]")
  , ("runtime/rust/Cargo.lock", cargo "name = \"lawspec-runtime-conformance\"")
  -- canon fails its check once this version reaches an open decision's or an
  -- exemption's revisit version.
  , ("canon.yaml", lineValue "version: ") ]
  where
    lineValue prefix old new = unlines . map (\l -> if l == prefix ++ old then prefix ++ new else l) . lines
    -- The first version line after the anchor.
    cargo anchor old new = unlines . go False . lines
      where go _ [] = []
            go True (l : rest) | l == "version = \"" ++ old ++ "\"" = ("version = \"" ++ new ++ "\"") : rest
            go seen (l : rest) = l : go (seen || l == anchor) rest

versionCommand :: [String] -> IO ()
versionCommand args = do
  version <- currentVersion
  case args of
    [] -> putStrLn version
    ["--check"] -> do
      mismatched <- fmap concat $ forM versionedFiles $ \(file, rewrite) -> do
        content <- readFile' file
        -- A file agrees when rewriting the version to a sentinel changes it.
        pure [file | rewrite version "0.0.0-sentinel" content == content]
      unless (null mismatched) $ do
        putStrLn ("Version " ++ version ++ " is not stated in: " ++ unwords mismatched)
        exitFailure
      putStrLn ("Version " ++ version ++ " is consistent.")
    _ -> die "usage: lawspec-dev version [--check]"

bumpCommand :: [String] -> IO ()
bumpCommand [new] = do
  unless (semver new) (die ("not a MAJOR.MINOR.PATCH version: " ++ new))
  old <- currentVersion
  when (old == new) (die ("already at " ++ new))
  forM_ versionedFiles $ \(file, rewrite) -> do
    content <- readFile' file
    let updated = rewrite old new content
    when (updated == content) (die (file ++ " does not state version " ++ old))
    writeFile file updated
  -- Install instructions name the version.
  docs <- filter (".md" `isSuffixOf`) <$> ((++) <$> walkFiles "docs" <*> pure ["README.md"])
  forM_ docs $ \file -> do
    exists <- doesFileExist file
    when exists $ do
      content <- readFile' file
      let updated = replace ("lawspec@" ++ old) ("lawspec@" ++ new) (replace ("lawspec-" ++ old ++ ".tgz") ("lawspec-" ++ new ++ ".tgz") (replace (".artifacts/" ++ old) (".artifacts/" ++ new) (replace ("v" ++ old) ("v" ++ new) content)))
      when (updated /= content) (writeFile file updated)
  generateCommand []
  putStrLn ("Version " ++ old ++ " -> " ++ new ++ ". Add a CHANGELOG.md section, then run make wasm.")
  where
    semver v = case splitDots v of
      [a, b, c] -> all (\p -> not (null p) && all isDigit p) [a, b, c]
      _ -> False
    splitDots s = case break (== '.') s of
      (a, _ : rest) -> a : splitDots rest
      (a, []) -> [a]
bumpCommand _ = die "usage: lawspec-dev bump <x.y.z>"

replace :: String -> String -> String -> String
replace needle new = go
  where go [] = []
        go s@(c : rest) | needle `isPrefixOf` s = new ++ go (drop (length needle) s)
                        | otherwise = c : go rest

readIfExists :: FilePath -> IO (Maybe String)
readIfExists path = do
  exists <- doesFileExist path
  if exists then Just <$> readFile' path else pure Nothing

executableFile :: FilePath -> IO Bool
executableFile path = executable <$> getPermissions path

setExecutable :: FilePath -> Bool -> IO ()
setExecutable path value = do
  permissions <- getPermissions path
  when (executable permissions /= value) (setPermissions path (setOwnerExecutable value permissions))

walkFiles :: FilePath -> IO [FilePath]
walkFiles dir = do
  exists <- doesDirectoryExist dir
  if not exists then pure [] else do
    entries <- sort . filter (not . ("." `isPrefixOf`)) <$> listDirectory dir
    concat <$> forM entries (\entry -> do
      let path = dir </> entry
      isDirectory <- doesDirectoryExist path
      if isDirectory then walkFiles path else pure [path])
