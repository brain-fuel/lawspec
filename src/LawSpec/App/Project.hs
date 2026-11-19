-- | The project a command works on, ported from the Node CLI: finding and
-- reading lawspec.edn (component.mjs findManifest and readManifest), the
-- compiler cache directory (compiler-cache.mjs cacheLocation and the CLI's
-- cacheDirectory), and the request every compile command shares.
-- ref:DEC-haskell-application-port ref:DEC-incremental-compilation
module LawSpec.App.Project
  ( findManifest,
    readManifest,
    parseEdn,
    manifestFailure,
    CacheLocation (..),
    cacheLocation,
    cacheDirectory,
    buildDigest,
    removeCreatedState,
    isoTime,
    environment,
    dependencyRanges,
    extension,
  )
where

import Control.Monad (forM_, when)
import Data.List (intercalate)
import Data.Version (showVersion)
import LawSpec.App.Command
import LawSpec.App.Compiler (callRaw)
import LawSpec.App.Files (atomicWrite, readOptionalDirectory)
import LawSpec.App.Json
import LawSpec.Digest (digest, digestHex)
import LawSpec.Host.Effect
import LawSpec.Host.Path (join, resolve, takeDirectory)
import LawSpec.Manifest.EDN (ManifestError (..), encodeManifestJSON, parseManifest)
import Paths_lawspec (version)

-- | component.mjs fail(message, file): the message after the file, and one
-- manifest diagnostic at the file's start.
manifestFailure :: (Monad m) => String -> Maybe FilePath -> Command m a
manifestFailure message file =
  failWithDiagnostics
    (maybe "" (++ ": ") file ++ message)
    (JArray [jsObject ([("code", JString "manifest"), ("message", JString message)] ++ maybe [] (\f -> [("at", position f)]) file)])

position :: FilePath -> Json
position file = JObject [("file", JString file), ("line", integer 1), ("column", integer 1)]

-- | path.extname.
extension :: FilePath -> String
extension file = case break (== '.') (reverse name) of
  (_, []) -> ""
  (suffix, _ : before)
    | null before -> ""
    | otherwise -> '.' : reverse suffix
  where
    name = reverse (takeWhile (/= '/') (reverse file))

-- | Whether a path names a regular file (after links), as stat().isFile().
isFile :: (Monad m) => FilePath -> Command m Bool
isFile file = do
  grantRead [file]
  either (const False) ((== FileKind) . statusKind) <$> effectOr (Stat Follow file)

-- | component.mjs findManifest: lawspec.edn here or in a parent, refusing
-- the JSON manifests LawSpec no longer reads.
findManifest :: (Monad m) => FilePath -> Command m FilePath
findManifest start = go start
  where
    go directory = do
      let candidate = join directory "lawspec.edn"
      found <- isFile candidate
      if found
        then pure candidate
        else do
          forM_ ["lawspec.json", "lawspec-package.json"] $ \old -> do
            present <- isFile (join directory old)
            when present (manifestFailure (old ++ " is no longer supported; use lawspec.edn") (Just (join directory old)))
          let parent = takeDirectory directory
          if parent == directory
            then manifestFailure "No lawspec.edn found in this directory or its parents" (Just start)
            else go parent

-- | component.mjs parseManifest: the EDN document as JavaScript reads it.
parseEdn :: (Monad m) => String -> FilePath -> Command m Json
parseEdn text file = case parseManifest text of
  Left (ManifestError message) -> manifestFailure message (Just file)
  Right value -> either failWith pure (parseJson (encodeManifestJSON value))

-- | component.mjs readManifest: parse, then admit through the compiler's
-- componentManifest service; the admitted manifest is the response's.
readManifest :: (Monad m) => FilePath -> Command m Json
readManifest file = do
  when (extension file /= ".edn") $
    manifestFailure "LawSpec component and package manifests must use lawspec.edn; JSON configuration is no longer supported" (Just file)
  grantRead [file]
  bytes <- effect (nodeFailure "open" file) (ReadFile file)
  parsed <- parseEdn (fromUtf8 bytes) file
  result <- callRaw "componentManifest" (JObject [("manifest", parsed)])
  case member "diagnostics" result of
    Just (JArray items@(_ : _)) ->
      failWithDiagnostics
        (file ++ ": " ++ intercalate "\n" [maybe "undefined" jsString (member "message" item) | item <- items])
        (JArray [setMember "at" (position file) item | item <- items])
    _ -> pure (maybe JNull id (member "manifest" result))

-- | process.env[name], treating an unreadable environment as unset.
environment :: (Monad m) => String -> Command m (Maybe String)
environment name = either (const Nothing) id <$> effectOr (GetEnvironment name)

-- | dependencyRanges(manifest): each dependency's version range.
dependencyRanges :: Json -> Json
dependencyRanges manifest =
  jsObject
    [ (name, range)
    | (name, value) <- maybe [] members (member "dependencies" manifest),
      Just range <- [case value of JString _ -> Just value; _ -> member "version" value]
    ]

data CacheLocation = CacheLocation
  { cacheFolder :: FilePath,
    cacheOwned :: Bool,
    cacheSource :: String
  }
  deriving (Eq, Show)

-- | compiler-cache.mjs cacheLocation.
cacheLocation :: (Monad m) => Bool -> Json -> FilePath -> FilePath -> Command m (Maybe CacheLocation)
cacheLocation noCache config configRoot cwd
  | noCache || member "cache" config == Just (JBool False) = pure Nothing
  | otherwise = do
      variable <- environment "LAWSPEC_COMPILER_CACHE"
      pure . Just $ case (variable, member "cacheDirectory" config) of
        (Just directory, _) | not (null directory) -> CacheLocation (resolve cwd directory) False "LAWSPEC_COMPILER_CACHE"
        (_, Just directory) -> CacheLocation (resolve configRoot (jsString directory)) False ":cache-directory"
        _ -> CacheLocation (join configRoot ".lawspec/cache") True "default"

-- | The compiler build: the host's digest of the core module, or for a core
-- without one (the native executable, whose compiler adds a folder for its
-- own build), the digest of its version.
buildDigest :: Invocation -> String
buildDigest invocation = case invocationBuild invocation of
  Just build | length build >= 16 -> build
  _ -> digestHex (digest (utf8 ("lawspec " ++ showVersion version)))

-- | The Node CLI's cacheDirectory(config): where the compiler keeps its
-- entries, as the directory the request names. The Node launcher puts each
-- build's entries in a folder of its own below the directory it is given,
-- so this names that folder. LawSpec owns only the project's .lawspec/cache:
-- it writes a .gitignore there and removes other builds' folders, and a
-- failed command removes the .lawspec folder if this run created it.
cacheDirectory :: (Monad m) => Invocation -> FilePath -> Maybe CacheLocation -> Command m (Maybe FilePath)
cacheDirectory _ _ Nothing = pure Nothing
cacheDirectory invocation configRoot (Just location)
  | not (cacheOwned location) = do
      grantWrite [folder]
      _ <- effectOr (MakeDirectories Nothing folder)
      pure (Just (join folder build))
  | otherwise = do
      let state = join configRoot ".lawspec"
      grantWrite [state]
      existing <- readOptionalDirectory state
      when (existing == Nothing) (modifySession (\s -> s {sessionCreatedState = Just state}))
      effect (nodeFailure "mkdir" folder) (MakeDirectories Nothing folder)
      atomicWrite (join folder ".gitignore") "*\n" False
      entries <- maybe [] id <$> readOptionalDirectory folder
      let receipts = "solver-goals-v1"
          stale = filter (`notElem` [build, ".gitignore", receipts]) entries
      forM_ (if null stale then [] else stale ++ [receipts]) $ \entry ->
        effectOr (Remove Recursive (join folder entry)) >>= \case
          Left problem | errorKind problem /= NotFound -> abort (nodeFailure "rm" (join folder entry) problem)
          _ -> pure ()
      pure (Just (join folder build))
  where
    folder = cacheFolder location
    build = take 16 (buildDigest invocation)

-- | main().catch: remove the .lawspec folder this run created.
removeCreatedState :: (Monad m) => Command m ()
removeCreatedState = do
  created <- sessionCreatedState <$> getSession
  forM_ created $ \state -> removeCreated Recursive state

-- | Date.prototype.toISOString for milliseconds since the epoch.
isoTime :: Integer -> String
isoTime milliseconds =
  pad 4 year ++ "-" ++ pad 2 month ++ "-" ++ pad 2 day ++ "T" ++ pad 2 hours ++ ":" ++ pad 2 minutes ++ ":" ++ pad 2 seconds ++ "." ++ pad 3 millis ++ "Z"
  where
    (days, inDay) = milliseconds `divMod` 86400000
    (hours, inHour) = inDay `divMod` 3600000
    (minutes, inMinute) = inHour `divMod` 60000
    (seconds, millis) = inMinute `divMod` 1000
    -- Howard Hinnant's civil_from_days.
    z = days + 719468
    era = z `div` 146097
    doe = z - era * 146097
    yoe = (doe - doe `div` 1460 + doe `div` 36524 - doe `div` 146096) `div` 365
    doy = doe - (365 * yoe + yoe `div` 4 - yoe `div` 100)
    mp = (5 * doy + 2) `div` 153
    day = doy - (153 * mp + 2) `div` 5 + 1
    month = if mp < 10 then mp + 3 else mp - 9
    year = yoe + era * 400 + (if month <= 2 then 1 else 0)
    pad width value = let text = show value in replicate (width - length text) '0' ++ text
