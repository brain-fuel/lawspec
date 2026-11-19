-- \$XDG_CACHE_HOME/lawspec/packages or ~/.cache/lawspec/packages): each
-- unpacked under the SHA-256 of its canonical source, beside a .sha256
-- marker with its content digest, and each Git remote as a bare repository
-- under git/<SHA-256 of its URL>. The cache is granted only when a package
-- needs it, as a write root (a read root for read-only resolution).
--
-- Git runs through spawn exactly as the Node CLI ran it; archives are
-- fetched over HTTPS by the host, with redirects followed here as fetch()
-- followed them, checked against their SHA-256 and unpacked by
-- "LawSpec.Archive.Tar" and "LawSpec.Archive.Deflate".
--
-- As the Node CLI did, a cache entry is prepared under a temporary name in
-- the cache (mkdtemp's 0700 directory: the bare repository git init makes
-- there, or the unpacked and checked archive) and renamed into place, so a
-- concurrent run never observes a partly written entry; a run that finds
-- the entry already there keeps that one. Unpacked files and directories
-- get the archive's modes as node-tar's extract gives them, and a packed
-- file's mode is node-tar's portable mode. Where component-packages.mjs compares real paths, this
-- checks each component below the root with lstat and treats a symbolic
-- link as leaving the root; files.mjs and filesUnder refuse links in
-- package contents anyway.
-- ref:DEC-haskell-application-port

-- | Contract package resolution, ported from component-packages.mjs
-- resolveDependencies: the manifest's dependencies, chosen among the
-- packages its :packages entries supply, named by path, fetched from Git or
-- downloaded as archives, with lawspec.lock.edn read, checked and rewritten
-- as the Node CLI does; and packComponent, the archive lawspec package
-- writes.
--
-- Fetched packages live in the package cache (LAWSPEC_CACHE_DIR, else
module LawSpec.App.Packages
  ( Resolved (..),
    ResolveOptions (..),
    Update (..),
    resolveOptions,
    resolveDependencies,
    packageDigest,
    packComponent,
    validateLock,
    lockName,
    toManifest,
    download,
    archiveEntries,
    freshDirectory,
    renameInto,
  )
where

import Control.Monad (forM, forM_, unless, when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.State.Strict (StateT, gets, modify', runStateT)
import qualified Data.ByteString as B
import Data.Char (isAlpha, isDigit, isUpper, ord, toLower)
import Data.List (intercalate, isPrefixOf, sortBy)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Ord (comparing)
import qualified Data.Set as S
import LawSpec.App.Command
import LawSpec.App.Compiler (callRaw)
import LawSpec.App.Files (atomicWrite, collectSources, compareUtf16, digestText, readOptional)
import LawSpec.App.Json
import LawSpec.App.Process (Launch (..), Run (..), commandFailed, launch, resolveTool, runProcess, runSucceeded)
import LawSpec.App.Project (dependencyRanges, environment, parseEdn, readManifest)
import LawSpec.Archive.Deflate (gunzip, gzip)
import LawSpec.Archive.Tar (Unpacked (..), portableMode, readTar, unpackEntries, writeTar)
import LawSpec.Digest (digest, digestHex)
import LawSpec.Host.Effect hiding (Entry (..))
import qualified LawSpec.Host.Effect as Effect
import LawSpec.Host.Path (join, relative, resolve, takeDirectory, within)
import LawSpec.Host.Policy (Policy (..))
import LawSpec.Manifest.EDN (ManifestValue (..), writeManifest)

-- | options.update: no refresh, every package, or the one named.
data Update = NoUpdate | UpdateAll | UpdateOne String
  deriving (Eq, Show)

data ResolveOptions = ResolveOptions
  { resolveLocked :: Bool,
    resolveReadOnly :: Bool,
    resolveWriteLock :: Bool,
    resolveOffline :: Bool,
    resolveUpdate :: Update,
    -- | The working directory: relative cache and Git paths resolve
    -- against it, and Git runs in it.
    resolveDirectory :: FilePath
  }

-- | No refresh, writing the lockfile, online unless the environment says.
resolveOptions :: FilePath -> ResolveOptions
resolveOptions = ResolveOptions False False True False NoUpdate

data Resolved = Resolved
  { resolvedPackages :: [Json],
    resolvedIdentities :: [Json],
    resolvedLock :: Json
  }

data Locked = Locked
  { lockedName :: String,
    lockedVersion :: String,
    lockedSource :: Json,
    lockedDigest :: Maybe String,
    lockedDependencies :: [(String, String)]
  }

data Identity = Identity {identityName :: String, identityVersion :: String, identitySource :: Json, identityDigest :: String}

data State = State
  { stateSelections :: [(String, Json)],
    -- | In insertion order, as the Node CLI's Maps.
    stateEntries :: [(String, Locked)],
    stateIdentities :: [(String, Identity)],
    statePackages :: [(String, Json)],
    stateLocal :: M.Map String [(FilePath, Json)],
    stateLocalSeen :: S.Set FilePath,
    stateLocations :: M.Map String FilePath,
    -- | The package cache, once a package needed it.
    stateCache :: Maybe FilePath
  }

-- | What one resolution works with, besides its state.
data Context = Context
  { contextRoot :: FilePath,
    contextPrevious :: Maybe Json,
    contextOldSelections :: [(String, Json)],
    contextOptions :: ResolveOptions,
    contextOffline :: Bool
  }

type Resolve m = StateT State (Command m)

lockName :: String
lockName = "lawspec.lock.edn"

-- | component-packages.mjs resolveDependencies.
resolveDependencies :: (Monad m) => FilePath -> Json -> ResolveOptions -> Command m Resolved
resolveDependencies file manifest options = do
  let root = takeDirectory (resolve (resolveDirectory options) file)
      lockFile = join root lockName
  offlineVariable <- environment "LAWSPEC_OFFLINE"
  let offline = resolveReadOnly options || resolveOffline options || offlineVariable == Just "1"
  previousText <- grantRead [lockFile] >> readOptional lockFile
  previous <- traverse (\content -> parseEdn content lockFile) previousText
  forM_ previous validateLock
  let oldSelections = maybe [] (maybe [] members . member "selections") previous
      context = Context root previous oldSelections options offline
  (roots, state) <-
    runStateT
      ( do
          localCandidates root manifest
          forM (sortedEntries (member "dependencies" manifest)) $ \(name, specification) -> do
            identity <- resolveOne context name specification root "$" []
            pure (name, JString identity)
      )
      (State [] [] [] [] M.empty S.empty M.empty Nothing)
  let lock =
        JObject
          [ ("format", JString "lawspec-lock"),
            ("version", integer 1),
            ("roots", jsObject roots),
            ("selections", jsObject (stateSelections state)),
            ("packages", JArray [entryJson identity entry | (identity, entry) <- sortBy (comparing fst) (stateEntries state)])
          ]
  when (not (null (stateEntries state)) || isJust previous) $ do
    let different = Just (canonical lock) /= fmap canonical previous
    when (resolveLocked options && different) (failWith "Lockfile is out of date; run lawspec fetch")
    when (not (resolveLocked options) && not (resolveReadOnly options) && resolveWriteLock options && different) $ do
      grantWrite [lockFile]
      atomicWrite lockFile (writeManifest False (toManifest lock)) False
  let entries = M.fromList (stateEntries state)
      identities = M.fromList (stateIdentities state)
      closure memo identity = case M.lookup identity memo of
        Just value -> (value, memo)
        Nothing ->
          let entry = entries M.! identity
              (children, memo') =
                foldl
                  (\(kept, known) (name, child) -> let (childDigest, known') = closure known child in (kept ++ [(name, JString childDigest)], known'))
                  ([], memo)
                  (lockedDependencies entry)
              content = identityDigest (identities M.! identity)
              value = if null children then content else digestText (canonical (JObject [("content", JString content), ("dependencies", jsObject children)]))
           in (value, M.insert identity value memo')
      (resolvedDigests, _) =
        foldl (\(kept, memo) (identity, _) -> let (value, memo') = closure memo identity in (kept ++ [(identity, value)], memo')) ([], M.empty) (stateIdentities state)
      resolved =
        [ JObject
            [ ("name", JString (identityName identity)),
              ("version", JString (identityVersion identity)),
              ("source", identitySource identity),
              ("digest", JString closureDigest),
              ("contentDigest", JString (identityDigest identity))
            ]
        | ((_, identity), (_, closureDigest)) <- zip (stateIdentities state) resolvedDigests
        ]
  forM_ resolved $ \identity ->
    when (any (\other -> sameRelease identity other && member "digest" other /= member "digest" identity) resolved) $
      failWith ("Ambiguous resolved contract closure for " ++ text "name" identity ++ " " ++ text "version" identity)
  pure (Resolved (ordered (map snd (statePackages state))) (ordered resolved) lock)
  where
    text key value = maybe "" jsString (member key value)
    sameRelease left right = text "name" left == text "name" right && text "version" left == text "version" right
    ordered = sortBy (\a b -> localeCompare (text "name" a) (text "name" b) <> localeCompare (text "version" a) (text "version" b))
    entryJson identity entry =
      JObject
        ( [ ("id", JString identity),
            ("name", JString (lockedName entry)),
            ("version", JString (lockedVersion entry)),
            ("source", lockedSource entry)
          ]
            ++ [("digest", JString value) | Just value <- [lockedDigest entry]]
            ++ [("dependencies", jsObject [(name, JString child) | (name, child) <- lockedDependencies entry])]
        )

-- | Object.entries(value ?? {}).sort(): each pair as the string
-- "name,value" in UTF-16 order.
sortedEntries :: Maybe Json -> [(String, Json)]
sortedEntries value = sortBy (\(a, x) (b, y) -> compareUtf16 (a ++ "," ++ jsString x) (b ++ "," ++ jsString y)) (maybe [] members value)

localCandidates :: (Monad m) => FilePath -> Json -> Resolve m ()
localCandidates directory owner =
  forM_ [name | Just names <- [member "packages" owner >>= arrayOf], JString name <- names] $ \name -> do
    let location = resolve directory name
    seen <- gets stateLocalSeen
    unless (S.member location seen) $ do
      modify' (\s -> s {stateLocalSeen = S.insert location (stateLocalSeen s)})
      candidate <- lift (readManifest (join location "lawspec.edn"))
      when (isNothing (member "package" candidate)) (lift (failWith (location ++ ": expected a package identity")))
      let packageName = maybe "" jsString (member "package" candidate >>= member "name")
      modify' (\s -> s {stateLocal = M.insertWith (flip (++)) packageName [(location, candidate)] (stateLocal s)})
      localCandidates location candidate

packageVersions :: (Monad m) => Maybe Json -> [String] -> Command m [String]
packageVersions range versions = do
  result <- callRaw "packageVersions" (JObject (maybe [] (\r -> [("range", r)]) range ++ [("versions", JArray (map JString versions))]))
  case member "diagnostics" result of
    Just (JArray items@(_ : _)) ->
      failWithDiagnostics (intercalate "\n" [maybe "undefined" jsString (member "message" item) | item <- items]) (JArray items)
    _ -> pure [version | Just items <- [member "versions" result >>= arrayOf], JString version <- items]

rangeOf :: Json -> Maybe Json
rangeOf value@(JString _) = Just value
rangeOf value = member "version" value

field :: String -> Json -> Maybe String
field key value = member key value >>= stringOf

kindOf :: Json -> Maybe String
kindOf = field "kind"

-- | A string field that JavaScript finds truthy.
nonEmpty :: Maybe String -> Maybe String
nonEmpty value = case value of
  Just text | not (null text) -> Just text
  _ -> Nothing

trim :: String -> String
trim = reverse . dropWhile (`elem` (" \t\n\r" :: String)) . reverse . dropWhile (`elem` (" \t\n\r" :: String))

resolveOne :: (Monad m) => Context -> String -> Json -> FilePath -> String -> [String] -> Resolve m String
resolveOne context name specification directory owner ancestry = do
  let key = owner ++ "::" ++ name
  (location, source) <- materialize context name specification directory (lookup key (contextOldSelections context)) owner
  described <- lift (readManifest (join location "lawspec.edn"))
  let identity = member "package" described
  when (fmap jsString (identity >>= member "name") /= Just name) $
    lift (failWith ("Dependency " ++ name ++ " has a different package identity"))
  let version = maybe "undefined" jsString (identity >>= member "version")
  forM_ (nonEmpty (field "tagVersion" source)) $ \tagVersion ->
    when (tagVersion /= version) $
      lift (failWith ("Git tag version " ++ tagVersion ++ " differs from " ++ name ++ " manifest version " ++ version))
  accepted <- lift (packageVersions (rangeOf specification) [version])
  when (null accepted) $
    lift (failWith ("requires " ++ name ++ " " ++ maybe "undefined" jsString (rangeOf specification) ++ ", but version " ++ version ++ " is supplied"))
  let identifier = digestText (canonical (JObject [("name", JString name), ("version", JString version), ("source", source)]))
  modify' (\s -> s {stateSelections = assign key (JObject [("request", specification), ("package", JString identifier)]) (stateSelections s)})
  when (identifier `elem` ancestry) $
    lift (failWith ("Package dependency cycle: " ++ intercalate " -> " (ancestry ++ [identifier])))
  known <- gets (lookup identifier . stateEntries)
  case known of
    Just _ -> pure identifier
    Nothing -> do
      content <- lift (packageDigest location)
      identities <- gets stateIdentities
      when (any (\(_, other) -> identityName other == name && identityVersion other == version && identityDigest other /= content) identities) $
        lift (failWith ("Ambiguous content for " ++ name ++ " " ++ version))
      let contentDigest = if kindOf source == Just "path" then Nothing else Just content
      modify' $ \s ->
        s
          { stateEntries = stateEntries s ++ [(identifier, Locked name version source contentDigest [])],
            stateIdentities = stateIdentities s ++ [(identifier, Identity name version source content)],
            stateLocations = M.insert identifier location (stateLocations s)
          }
      localCandidates location described
      forM_ (sortedEntries (member "dependencies" described)) $ \(dependency, child) -> do
        resolvedChild <- resolveOne context dependency child location identifier (ancestry ++ [identifier])
        modify' $ \s ->
          s {stateEntries = [(i, if i == identifier then e {lockedDependencies = assign dependency resolvedChild (lockedDependencies e)} else e) | (i, e) <- stateEntries s]}
      sources <- lift (collectSources location [entry | Just items <- [member "sources" described >>= arrayOf], JString entry <- items] (contextRoot context))
      modify' $ \s ->
        s
          { statePackages =
              statePackages s
                ++ [ ( identifier,
                       JObject
                         [ ("name", JString name),
                           ("version", JString version),
                           ("dependencies", dependencyRanges described),
                           ("sources", JArray [JObject [("path", JString path'), ("content", JString text)] | (path', text) <- sources])
                         ]
                     )
                   ]
          }
      pure identifier
  where
    assign key value fields = if any ((== key) . fst) fields then [(k, if k == key then value else v) | (k, v) <- fields] else fields ++ [(key, value)]

-- | The nearest owner whose content is immutable (fetched, not a path),
-- through the embedded packages between.
immutableOwner :: (Monad m) => String -> Resolve m (Maybe String)
immutableOwner owner = do
  entries <- gets stateEntries
  let go current = case lookup current entries of
        Just entry
          | kindOf (lockedSource entry) == Just "embedded" -> go (fromMaybe "" (field "parent" (lockedSource entry)))
          | kindOf (lockedSource entry) /= Just "path" -> Just current
        _ -> Nothing
  pure (go owner)

-- | localSource: a package on disk, by path, or embedded in the fetched
-- package that owns it.
localSource :: (Monad m) => Context -> FilePath -> String -> Resolve m (FilePath, Json)
localSource context location owner = do
  parent <- immutableOwner owner
  case parent of
    Nothing -> pure (location, JObject [("kind", JString "path"), ("path", JString (orDot (relative (contextRoot context) location)))])
    Just identifier -> do
      directory <- gets (fromMaybe "" . M.lookup identifier . stateLocations)
      ok <- if within directory location then lift (realInside directory location) else pure False
      unless ok (lift (failWith "Published package dependency leaves its downloaded root"))
      pure (location, JObject [("kind", JString "embedded"), ("parent", JString identifier), ("path", JString (orDot (relative directory location)))])
  where
    orDot text = if null text then "." else text

materialize :: (Monad m) => Context -> String -> Json -> FilePath -> Maybe Json -> String -> Resolve m (FilePath, Json)
materialize context name specification directory old owner = case old of
  Just selection
    | not refresh,
      Just request <- member "request" selection,
      canonical request == canonical specification -> do
        let wanted = member "package" selection
            lockEntries = fromMaybe [] (contextPrevious context >>= member "packages" >>= arrayOf)
        entry <- case [e | e <- lockEntries, member "id" e == wanted] of
          e : _ -> pure e
          [] -> lift (failWith ("Lockfile references missing package " ++ maybe "undefined" jsString wanted))
        let source = fromMaybe JNull (member "source" entry)
        case kindOf source of
          Just "path" -> do
            immutable <- immutableOwner owner
            when (isJust immutable) (lift (failWith "Lockfile contains a non-portable published path; run lawspec update"))
            pure (resolve root (fromMaybe "" (field "path" source)), source)
          Just "embedded" -> do
            let parentId = fromMaybe "" (field "parent" source)
            parent <- gets (M.lookup parentId . stateLocations)
            immutable <- immutableOwner owner
            case parent of
              Just parentDirectory | immutable == Just parentId -> do
                loaded <- localSource context (resolve parentDirectory (fromMaybe "" (field "path" source))) owner
                content <- lift (packageDigest (fst loaded))
                when (Just content /= field "digest" entry) (lift (failWith ("Cached embedded contract content changed: " ++ name)))
                pure loaded
              _ -> lift (failWith "Invalid embedded package parent in lockfile")
          _ -> downloaded context source (Just entry)
  _ -> fresh
  where
    root = contextRoot context
    options = contextOptions context
    refresh = case resolveUpdate options of
      UpdateAll -> True
      UpdateOne named -> named == name
      NoUpdate -> False
    fresh = do
      when (resolveLocked options) (lift (failWith ("Lockfile must change for " ++ name ++ "; run lawspec fetch without --locked")))
      case specification of
        JString range -> do
          candidates <- gets (fromMaybe [] . M.lookup name . stateLocal)
          let versionOf (_, candidate) = maybe "undefined" jsString (member "package" candidate >>= member "version")
          accepted <- lift (packageVersions (Just (JString range)) (map versionOf candidates))
          case [candidate | candidate <- candidates, Just (versionOf candidate) == firstOf accepted] of
            (location, _) : _ -> localSource context location owner
            [] ->
              lift . failWith $
                "requires "
                  ++ name
                  ++ " "
                  ++ range
                  ++ ", but "
                  ++ case candidates of
                    [only] -> "version " ++ versionOf only ++ " is supplied"
                    _ -> "no supplied version satisfies it"
        _
          | Just path' <- nonEmpty (field "path" specification) -> localSource context (resolve directory path') owner
          | Just url <- nonEmpty (field "archive" specification) ->
              downloaded context (jsObject ([("kind", JString "archive"), ("url", JString url)] ++ [("sha256", value) | Just value <- [member "sha256" specification]])) Nothing
          | otherwise -> do
              when (contextOffline context) (lift (failWith ("Offline: resolving " ++ name ++ " requires a lockfile")))
              let url = fromMaybe "" (field "git" specification)
              (ref, tagVersion) <- case nonEmpty (field "rev" specification) of
                Just rev -> pure (rev, Nothing)
                Nothing -> lift (latestTag context name specification url)
              commit <- fetchRevision context url ref
              downloaded
                context
                ( JObject
                    ( [("kind", JString "git"), ("url", JString url), ("commit", JString commit)]
                        ++ [("tagVersion", JString version) | Just version <- [tagVersion]]
                        ++ [("subdir", JString subdir) | Just subdir <- [nonEmpty (field "subdir" specification)]]
                    )
                )
                Nothing
    firstOf (first : _) = Just first
    firstOf [] = Nothing

-- | The newest tag of a Git remote whose version, after the tag prefix,
-- satisfies the dependency's range: its commit (or tag object) and version.
latestTag :: (Monad m) => Context -> String -> Json -> String -> Command m (String, Maybe String)
latestTag context name specification url = do
  listing <- gitText context ["ls-remote", "--tags", "--refs", "--", url]
  let prefix = fromMaybe "v" (field "tagPrefix" specification)
      tags =
        [ (commit, tag)
        | line <- lines (trim listing),
          not (null line),
          (commit, reference) <- [splitWhitespace line],
          let tag = replaceFirst "refs/tags/" reference,
          prefix `isPrefixOf` tag,
          semantic (drop (length prefix) tag)
        ]
  versions <- packageVersions (member "version" specification) [drop (length prefix) tag | (_, tag) <- tags]
  case [(commit, drop (length prefix) tag) | (commit, tag) <- tags, Just (drop (length prefix) tag) == firstOf versions] of
    (commit, version) : _ -> pure (commit, Just version)
    [] -> failWith ("No published Git version satisfies " ++ name ++ " " ++ maybe "undefined" jsString (member "version" specification))
  where
    firstOf (first : _) = Just first
    firstOf [] = Nothing
    -- line.split(/\s+/): the first two fields.
    splitWhitespace line =
      let (first, rest) = break isSpace' line
          (second, _) = break isSpace' (dropWhile isSpace' rest)
       in (first, second)
    isSpace' c = c `elem` (" \t\n\r\f\v" :: String)
    replaceFirst needle haystack = go "" haystack
      where
        go seen rest@(c : more)
          | needle `isPrefixOf` rest = reverse seen ++ drop (length needle) rest
          | otherwise = go (c : seen) more
        go seen [] = reverse seen

-- | /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/
semantic :: String -> Bool
semantic text = case number text of
  Just ('.' : rest) -> case number rest of
    Just ('.' : rest') -> maybe False suffixes (number rest')
    _ -> False
  _ -> False
  where
    number s = let (ds, rest) = span isDigit s in if null ds then Nothing else Just rest
    identifier c = isDigit c || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '.' || c == '-'
    part rest continue = let (taken, after) = span identifier rest in not (null taken) && continue after
    suffixes s = case s of
      [] -> True
      '-' : rest -> part rest build
      '+' : rest -> part rest null
      _ -> False
    build s = case s of
      [] -> True
      '+' : rest -> part rest null
      _ -> False

-- | Fetch one revision of a remote into its cached repository and name the
-- commit it is, through a temporary ref that is deleted afterwards.
fetchRevision :: (Monad m) => Context -> String -> String -> Resolve m String
fetchRevision context url ref = do
  repository <- gitRepository context url
  clock <- lift (either (const (Clock 0 0)) id <$> effectOr GetClock)
  let fetched = "refs/lawspec/" ++ take 32 (digestText (url ++ "\n" ++ ref ++ "\n" ++ show (wallMilliseconds clock) ++ "\n" ++ show (monotonicMicroseconds clock)))
  lift $ do
    outcome <-
      recover
        ( do
            _ <- gitText context ["--git-dir", repository, "fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--", url, ref ++ ":" ++ fetched]
            Right . trim <$> gitText context ["--git-dir", repository, "rev-parse", fetched ++ "^{commit}"]
        )
        (pure . Left)
    -- The ref is deleted in a finally block: its failure, when it fails,
    -- is the one reported.
    deleted <- runGit context ["--git-dir", repository, "update-ref", "-d", fetched]
    either failWith (const (pure ())) deleted
    either abort pure outcome

-- | The package cache, granted on first use: writable, or readable only
-- when resolution is read-only.
packageCache :: (Monad m) => Context -> Resolve m FilePath
packageCache context = do
  kept <- gets stateCache
  case kept of
    Just cache -> pure cache
    Nothing -> do
      let cwd = resolveDirectory (contextOptions context)
      explicit <- lift (environment "LAWSPEC_CACHE_DIR")
      cache <- case explicit of
        Just value -> pure (resolve cwd value)
        Nothing -> do
          xdg <- lift (environment "XDG_CACHE_HOME")
          home <- lift (environment "HOME")
          let base = fromMaybe (joinPath (fromMaybe "/" home) ".cache") xdg
          pure (resolve cwd (joinPath (joinPath base "lawspec") "packages"))
      lift $
        if resolveReadOnly (contextOptions context)
          then grantRead [cache]
          else grantWrite [cache]
      modify' (\s -> s {stateCache = Just cache})
      pure cache
  where
    joinPath left right = if null left then right else left ++ "/" ++ right

-- | The cached bare repository of a Git remote, initialised when missing.
gitRepository :: (Monad m) => Context -> String -> Resolve m FilePath
gitRepository context url = do
  cache <- packageCache context
  let repository = join cache ("git/" ++ digestText url)
  lift $ do
    present <- readOptional (join repository "HEAD")
    when (isNothing present) $ do
      effect (nodeFailure "mkdir" (takeDirectory repository)) (MakeDirectories Nothing (takeDirectory repository))
      temporary <- freshDirectory (takeDirectory repository) ".initializing-"
      outcome <-
        recover
          ( Right <$> do
              _ <- gitText context ["init", "--bare", "--quiet", temporary]
              renameInto [AlreadyExists, DirectoryNotEmpty, PermissionDenied] temporary repository
              initialised <- readOptional (join repository "HEAD")
              when (isNothing initialised) (failWith ("Cached Git repository initialization did not complete: " ++ repository))
          )
          (pure . Left)
      _ <- removeCreated Recursive temporary
      either abort pure outcome
    pure repository

-- | rename(temporary, entry) as the Node CLI placed a cache entry: an
-- entry another run placed first is kept, which rename reports with one of
-- the given kinds; any other failure is Node's rename error.
renameInto :: (Monad m) => [ErrorKind] -> FilePath -> FilePath -> Command m ()
renameInto tolerated temporary entry =
  effectOr (Rename temporary entry) >>= \case
    Right () -> pure ()
    Left problem
      | errorKind problem `elem` tolerated -> pure ()
      | otherwise -> abort (nodeFailure "rename" (temporary ++ "' -> '" ++ entry) problem)

-- | A git invocation as execFile ran it in the Node CLI: in the working
-- directory, with the host's environment; its standard output, or
-- execFile's error message.
runGit :: (Monad m) => Context -> [String] -> Command m (Either String B.ByteString)
runGit context arguments = do
  let cwd = resolveDirectory (contextOptions context)
  grantRead [cwd]
  found <- resolveTool cwd Nothing "git"
  case found of
    Left _ -> pure (Left "spawn git ENOENT")
    Right _ -> do
      let spec = (launch "git" arguments cwd) {launchLimit = Just (128 * 1024 * 1024)}
      run <- runProcess spec
      pure $
        if runSucceeded run
          then Right (runStdout run)
          else Left (if runOverLimit run then "stdout maxBuffer length exceeded" else commandFailed spec run)

gitText :: (Monad m) => Context -> [String] -> Command m String
gitText context arguments = runGit context arguments >>= either failWith (pure . fromUtf8)

-- | gitCheckout: the source's commit as a tar archive, fetched first when
-- the cached repository lacks it.
gitCheckout :: (Monad m) => Context -> Json -> Resolve m B.ByteString
gitCheckout context source = do
  let url = fromMaybe "" (field "url" source)
      commit = fromMaybe "" (field "commit" source)
  repository <- gitRepository context url
  lift $ do
    present <- runGit context ["--git-dir", repository, "cat-file", "-e", commit ++ "^{commit}"]
    case present of
      Right _ -> pure ()
      Left _ -> do
        when (contextOffline context) (failWith ("Offline: Git revision " ++ commit ++ " is not cached"))
        () <$ gitText context ["--git-dir", repository, "fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--", url, commit]
    archive <- runGit context ["--git-dir", repository, "archive", "--format=tar", maybe commit (\subdir -> commit ++ ":" ++ subdir) (nonEmpty (field "subdir" source))]
    either failWith pure archive

-- | An archive's bytes over HTTPS, following redirects as fetch() does.
download :: (Monad m) => String -> Command m B.ByteString
download url = do
  scheme <- case break (== ':') url of
    (name@(first : rest), ':' : _) | isAlpha first && all schemeCharacter rest -> pure (map toLower name)
    _ -> failWith "Invalid URL"
  let authority = takeWhile (`notElem` ("/?#" :: String)) (drop 3 (dropWhile (/= ':') url))
      host = case authority of
        '[' : rest -> '[' : takeWhile (/= ']') rest ++ "]"
        _ -> map toLower (takeWhile (/= ':') (reverse (takeWhile (/= '@') (reverse authority))))
      loopback = host `elem` ["127.0.0.1", "localhost", "[::1]"]
  unless (scheme == "https" || (scheme == "http" && loopback)) (failWith "Contract archives must use HTTPS")
  modifySession (\s -> s {sessionPolicy = (sessionPolicy s) {network = True}})
  follow (20 :: Int) url
  where
    schemeCharacter c = isAlpha c || isDigit c || c `elem` ("+-." :: String)
    follow budget current = do
      answer <- effectOr (Fetch (FetchRequest current "GET" [] Nothing))
      case answer of
        Left _ -> failWith "fetch failed"
        Right response
          | fetchStatus response `elem` [301, 302, 303, 307, 308],
            Just location <- lookup "location" [(map toLower name, value) | (name, value) <- fetchResponseHeaders response] ->
              if budget == 0 then failWith "fetch failed" else follow (budget - 1) (relativeUrl current location)
          | fetchStatus response < 200 || fetchStatus response > 299 ->
              failWith ("Contract download failed: HTTP " ++ show (fetchStatus response) ++ " for " ++ url)
          | otherwise -> pure (fetchResponseBody response)
    relativeUrl base location
      | "//" `isPrefixOf` location = takeWhile (/= ':') base ++ ":" ++ location
      | hasScheme location = location
      | "/" `isPrefixOf` location = origin base ++ location
      | otherwise = reverse (dropWhile (/= '/') (reverse (takeWhile (`notElem` ("?#" :: String)) base))) ++ location
    hasScheme text = case break (== ':') text of
      (first : rest, ':' : _) -> isAlpha first && all schemeCharacter rest
      _ -> False
    origin base = case break (== ':') base of
      (scheme, ':' : '/' : '/' : rest) -> scheme ++ "://" ++ takeWhile (`notElem` ("/?#" :: String)) rest
      _ -> base

-- | downloaded(source, known): the source unpacked in the package cache,
-- verified against the lock's digest or the cache's marker.
downloaded :: (Monad m) => Context -> Json -> Maybe Json -> Resolve m (FilePath, Json)
downloaded context source known = do
  cache <- packageCache context
  let identifier = digestText (canonical source)
      directory = join cache identifier
      marker = join cache (identifier ++ ".sha256")
      url = fromMaybe "undefined" (field "url" source)
      readOnly = resolveReadOnly (contextOptions context)
      offline = contextOffline context
      knownName = known >>= field "name"
  cachedManifest <- lift (readOptional (join directory "lawspec.edn"))
  reused <- case cachedManifest of
    Nothing -> pure False
    Just _ -> do
      expected <- case known of
        Just entry -> pure (field "digest" entry)
        Nothing -> fmap trim <$> lift (readOptional marker)
      case expected of
        Just value | not (null value) -> lift $ do
          unless (hex64 value) (failWith ("Cached contract content changed: " ++ fromMaybe url knownName))
          content <- packageDigest directory
          when (content /= value) (failWith ("Cached contract content changed: " ++ fromMaybe url knownName))
          unless readOnly (atomicWrite marker (value ++ "\n") False)
          pure True
        _ -> do
          when offline (lift (failWith ("Offline: cached contract integrity is unavailable for " ++ url)))
          pure False
  if reused
    then pure (directory, source)
    else do
      when readOnly $
        lift (failWith ("Read-only dependency resolution requires a verified unpacked cache for " ++ url ++ "; run lawspec fetch separately"))
      when (offline && kindOf source == Just "archive") (lift (failWith ("Offline: " ++ url ++ " is not cached")))
      bytes <-
        if kindOf source == Just "git"
          then gitCheckout context source
          else lift $ do
            body <- download url
            when (Just (digestHex (digest body)) /= field "sha256" source) (failWith ("Contract archive SHA-256 mismatch: " ++ url))
            pure body
      lift $ do
        effect (nodeFailure "mkdir" cache) (MakeDirectories Nothing cache)
        temporary <- freshDirectory cache ".unpack-"
        outcome <-
          recover
            ( Right <$> do
                archiveEntries bytes temporary >>= place
                _ <- readManifest (join temporary "lawspec.edn")
                content <- packageDigest temporary
                renameInto [AlreadyExists, DirectoryNotEmpty] temporary directory
                content' <- packageDigest directory
                when (content' /= content) (failWith ("Cached contract content changed: " ++ url))
                atomicWrite marker (content ++ "\n") False
            )
            (pure . Left)
        _ <- removeCreated Recursive temporary
        either abort pure outcome
        forM_ known $ \entry -> do
          content <- packageDigest directory
          when (Just content /= field "digest" entry) (failWith ("Downloaded contract content differs from lock: " ++ fromMaybe "undefined" knownName))
      pure (directory, source)
  where
    hex64 text = length text == 64 && all (`elem` ("0123456789abcdef" :: String)) text
    place = mapM_ $ \case
      MakeDirectory path' bits -> effect (nodeFailure "mkdir" path') (MakeDirectories (Just bits) path')
      MakeFile path' bits bytes -> effect (nodeFailure "open" path') (WriteFile Replace (Just bits) path' bytes)

-- | unpack(): a tar archive, gzipped or not, as the entries to create
-- below a directory; or why it cannot be unpacked safely.
archiveEntries :: (Monad m) => B.ByteString -> FilePath -> Command m [Unpacked]
archiveEntries bytes directory = do
  raw <-
    if B.take 2 bytes == B.pack [0x1f, 0x8b]
      then either (\problem -> failWith ("zlib: " ++ problem)) pure (gunzip bytes)
      else pure bytes
  entries <- either failWith pure (readTar raw)
  either failWith pure (unpackEntries directory entries)

-- | mkdtemp(prefix) inside a directory the command may write: a new
-- directory named by the prefix and six characters, with mode 0700.
freshDirectory :: (Monad m) => FilePath -> String -> Command m FilePath
freshDirectory parent prefix = do
  clock <- either (const (Clock 0 0)) id <$> effectOr GetClock
  let candidate = join parent (prefix ++ suffix (monotonicMicroseconds clock + wallMilliseconds clock))
  taken <- effectOr (Stat NoFollow candidate)
  case taken of
    Left problem | errorKind problem == NotFound -> candidate <$ effect (nodeFailure "mkdtemp" candidate) (MakeDirectories (Just 0o700) candidate)
    Right _ -> freshDirectory parent (prefix ++ "x")
    Left problem -> abort (nodeFailure "mkdtemp" candidate problem)
  where
    alphabet = ['a' .. 'z'] ++ ['A' .. 'Z'] ++ ['0' .. '9']
    suffix n = take 6 [alphabet !! fromInteger ((n `div` (62 ^ i)) `mod` 62) | i <- [0 :: Integer ..]]

-- | The lockfile's shape, as validateLock checks it.
validateLock :: (Monad m) => Json -> Command m ()
validateLock lock = unless valid (failWith "Invalid LawSpec lockfile; regenerate it with lawspec fetch")
  where
    isMap (JObject _) = True
    isMap _ = False
    hex64 value = case value of
      Just (JString text) -> length text == 64 && all (`elem` ("0123456789abcdef" :: String)) text
      _ -> False
    commit value = case value of
      Just (JString text) -> length text >= 40 && length text <= 64 && all (`elem` ("0123456789abcdef" :: String)) text
      _ -> False
    entries = fromMaybe [] (member "packages" lock >>= arrayOf)
    ids = [text | entry <- entries, Just (JString text) <- [member "id" entry]]
    distinct = length ids == S.size (S.fromList ids) && length ids == length entries
    string key value = case member key value of
      Just (JString _) -> True
      _ -> False
    entryValid entry =
      isMap entry
        && string "id" entry
        && string "name" entry
        && string "version" entry
        && maybe False isMap (member "dependencies" entry)
        && maybe False isMap (member "source" entry)
        && sourceValid entry (fromMaybe JNull (member "source" entry))
    sourceValid entry source = case member "kind" source of
      Just (JString "path") -> string "path" source
      Just (JString "embedded") -> string "parent" source && string "path" source && hex64 (member "digest" entry)
      Just (JString kind)
        | kind `elem` ["git", "archive"] ->
            string "url" source
              && hex64 (member "digest" entry)
              && (kind /= "git" || commit (member "commit" source))
              && (kind /= "archive" || hex64 (member "sha256" source))
      _ -> False
    known value = case value of
      JString text -> text `elem` ids
      _ -> False
    valid =
      isMap lock
        && member "format" lock == Just (JString "lawspec-lock")
        && member "version" lock == Just (integer 1)
        && maybe False isMap (member "roots" lock)
        && maybe False isMap (member "selections" lock)
        && isJust (member "packages" lock >>= arrayOf)
        && all entryValid entries
        && distinct
        && all (\(_, selection) -> isMap selection && isJust (member "request" selection) && maybe False known (member "package" selection)) (maybe [] members (member "selections" lock))
        && all known (map snd (maybe [] members (member "roots" lock)) ++ concat [map snd (maybe [] members (member "dependencies" entry)) | entry <- entries])

-- | writeManifest's conversion of a manifest or lock document.
toManifest :: Json -> ManifestValue
toManifest = \case
  JObject fields -> ManifestMap [(key, toManifest value) | (key, value) <- fields]
  JArray items -> ManifestVector (map toManifest items)
  JString text -> ManifestString text
  JNumber number -> ManifestInteger (round number)
  JBool flag -> ManifestBool flag
  JNull -> ManifestNil

-- | component-packages.mjs packageDigest: the SHA-256 of the canonical list
-- of the package's files with the SHA-256 of each one's bytes.
packageDigest :: (Monad m) => FilePath -> Command m String
packageDigest root = do
  manifest <- readManifest (join root "lawspec.edn")
  files <- packageFiles root manifest False root []
  rows <- forM files $ \file -> do
    let path' = join root file
    grantRead [path']
    bytes <- effect (nodeFailure "open" path') (ReadFile path')
    pure (JArray [JString file, JString (digestHex (digest bytes))])
  pure (digestText (canonical (JArray rows)))

-- | packComponent(file, output): the package's published files as the
-- gzipped tar node-tar wrote, with its path, SHA-256 and identity. Each
-- file's mode is its lstat permission bits in node-tar's portable form
-- ('portableMode'), so an executable is 0755 and a plain file 0644; 0644
-- where the host reports no bits.
packComponent :: (Monad m) => FilePath -> FilePath -> FilePath -> Command m Json
packComponent cwd file output = do
  when (reverse (takeWhile (/= '/') (reverse file)) /= "lawspec.edn") $
    failWith "Published packages require the canonical lawspec.edn filename"
  manifest <- readManifest file
  let root = takeDirectory (resolve cwd file)
      target = resolve cwd output
      parent = takeDirectory target
  when (isNothing (member "package" manifest)) (failWith "lawspec package --output requires a package identity")
  selected <- packageFiles root manifest True root []
  contents <- forM selected $ \name -> do
    let path' = join root name
    grantRead [path']
    status <- effect (nodeFailure "lstat" path') (Stat NoFollow path')
    bytes <- effect (nodeFailure "open" path') (ReadFile path')
    pure (name, maybe 0o644 portableMode (statusPermissions status), bytes)
  let archive = gzip (writeTar contents)
  missing <- missingAncestor parent
  forM_ missing $ \top -> do
    grantWrite [top]
    effect (nodeFailure "mkdir" parent) (MakeDirectories Nothing parent)
  grantWrite [target]
  effect (nodeFailure "open" target) (WriteFile Replace Nothing target archive)
  pure
    ( JObject
        [ ("file", JString target),
          ("sha256", JString (digestHex (digest archive))),
          ("package", fromMaybe JNull (member "package" manifest))
        ]
    )
  where
    -- The outermost missing directory on the way to a path, which
    -- mkdir -p creates; 'Nothing' when the path exists.
    missingAncestor path' = do
      grantRead [path']
      exists <- effectOr (Stat Follow path')
      case exists of
        Right _ -> pure Nothing
        Left _
          | path' == "/" -> pure Nothing
          | otherwise -> do
              above <- missingAncestor (takeDirectory path')
              pure (Just (fromMaybe path' above))

-- | inside(root, file).
inside :: FilePath -> FilePath -> Bool
inside = within

-- | Whether a path's real path stays inside a root's, without realpath: every
-- component below the root must exist and none may be a symbolic link.
-- realpath fails on a missing component, as here.
realInside :: (Monad m) => FilePath -> FilePath -> Command m Bool
realInside root location
  | not (inside root location) = pure False
  | otherwise = go root (splitPath (relative root location))
  where
    go _ [] = pure True
    go cursor (part : rest) = do
      let next = join cursor part
      grantRead [next]
      effectOr (Stat NoFollow next) >>= \case
        Left problem -> abort (nodeFailure "realpath" location problem)
        Right status
          | statusKind status == SymbolicLinkKind -> pure False
          | otherwise -> go next rest
    splitPath text = filter (not . null) (splitOn' text)
    splitOn' text = case break (== '/') text of
      (part, []) -> [part]
      (part, _ : more) -> part : splitOn' more

filesUnder :: (Monad m) => FilePath -> Command m [String]
filesUnder root = walk root ""
  where
    walk file path' = do
      grantRead [file]
      status <- effect (nodeFailure "lstat" file) (Stat NoFollow file)
      case statusKind status of
        SymbolicLinkKind -> failWith ("Contract packages cannot contain symbolic links: " ++ path')
        DirectoryKind -> do
          entries <- effect (nodeFailure "scandir" file) (ListDirectory file)
          fmap concat . forM (sortBy compareUtf16 (map Effect.entryName entries)) $ \name ->
            if name `elem` [".git", ".lawspec", "node_modules", "target", "bin", "obj"]
              then pure []
              else walk (join file name) (if null path' then name else path' ++ "/" ++ name)
        FileKind -> pure [path']
        _ -> pure []

packageFiles :: (Monad m) => FilePath -> Json -> Bool -> FilePath -> [FilePath] -> Command m [String]
packageFiles root manifest publish packageRoot ancestry = do
  when (root `elem` ancestry) (failWith "Package dependency cycle while collecting published files")
  let ancestry' = ancestry ++ [root]
      strings key = [entry | Just items <- [member key manifest >>= arrayOf], JString entry <- items]
  forM_ (strings "sources" ++ strings "assets") $ \entry -> do
    let location = resolve root entry
    ok <- if inside root location then realInside root location else pure False
    unless ok (failWith ("Published package path leaves its root: " ++ entry))
    _ <- filesUnder location
    pure ()
  sources <- collectSources root (strings "sources") root
  forM_ sources $ \(path', _) ->
    unless (inside root (resolve root path')) (failWith ("Published package source leaves its root: " ++ path'))
  assets <- fmap concat . forM (strings "assets") $ \entry -> do
    let location = resolve root entry
    unless (inside root location) (failWith ("Published package asset leaves its root: " ++ entry))
    status <- effect (nodeFailure "lstat" location) (Stat NoFollow location)
    case statusKind status of
      SymbolicLinkKind -> failWith ("Published package asset is a symbolic link: " ++ entry)
      DirectoryKind -> map (\nested -> relative root (join location nested)) <$> filesUnder location
      _ -> pure [entry]
  nested <- fmap concat . forM (maybe [] (map snd . members) (member "dependencies" manifest)) $ \dependency ->
    case member "path" dependency of
      Just (JString path') | not (null path') -> do
        let location = resolve root path'
        if not (inside packageRoot location)
          then if publish then failWith ("Published package dependency leaves its root: " ++ path') else pure []
          else do
            ok <- realInside packageRoot location
            unless ok (failWith "Published dependency leaves its root through a symbolic link")
            inner <- readManifest (join location "lawspec.edn")
            map (\file -> relative root (join location file)) <$> packageFiles location inner publish packageRoot ancestry'
      _ -> pure []
  pure (sortBy compareUtf16 (S.toList (S.fromList (["lawspec.edn"] ++ map fst sources ++ assets ++ nested))))

-- | String.prototype.localeCompare for package names and versions, as ICU's
-- root collation orders them: punctuation, then digits, then letters
-- without regard to case, and lower case first among otherwise equal names.
localeCompare :: String -> String -> Ordering
localeCompare left right = comparing (map primary) left right <> comparing (map tertiary) left right
  where
    primary c
      | c == '_' = (0 :: Int, ord c)
      | c == '-' = (1, 0)
      | c == ',' = (2, 0)
      | c == '.' = (3, 0)
      | isDigit c = (5, ord c)
      | isAlpha c = (6, ord (toLower c))
      | c == '+' = (4, 0)
      | otherwise = (4, ord c)
    tertiary c = isUpper c
