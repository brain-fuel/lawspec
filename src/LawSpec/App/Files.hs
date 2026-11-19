-- | Generated-file ownership and safe writes, ported from the Node CLI's
-- files.mjs: source discovery, output path checks, atomic writes, and the
-- plan/apply pair that records which generated files LawSpec owns in
-- @.lawspec/generated.json@ and refuses to overwrite or remove a file that
-- someone edited. Texts and orders match files.mjs.
--
-- The host has no realpath, so 'safePath' checks each existing component
-- with lstat. files.mjs refuses a symbolic-link component before it
-- compares real paths, and with no link below the root a component's real
-- path is always inside the root's, so that comparison cannot fail.
-- ref:DEC-haskell-application-port ref:DEC-host-effect-abi
module LawSpec.App.Files
  ( Artifact (..),
    Ownership (..),
    Change (..),
    Action (..),
    Plan (..),
    AdapterUpdate (..),
    digestText,
    readOptional,
    readOptionalDirectory,
    safePath,
    atomicWrite,
    planWrites,
    applyWrites,
    collectSources,
    compareUtf16,
    artifactsFrom,
    actionName,
  )
where

import Control.Monad (foldM, forM, forM_, when)
import qualified Data.ByteString as B
import Data.Char (ord)
import Data.List (isSuffixOf, sortBy)
import qualified Data.Set as S
import LawSpec.App.Command
import LawSpec.App.Json
import LawSpec.Digest (digest, digestHex)
import LawSpec.Host.Effect hiding (Create)
import qualified LawSpec.Host.Effect as Effect
import LawSpec.Host.Path (isAbsolute, join, relative, resolve)

data Ownership = Generated | User | UnknownOwnership deriving (Eq, Show)

-- | A planned output from the compiler (planGeneration's files).
data Artifact = Artifact
  { artifactPath :: String,
    artifactContent :: String,
    artifactOwnership :: Ownership,
    -- | A user file's canonical scaffold, compared instead of its content;
    -- 'Left' when the compiler sent something other than a string.
    artifactAdapterReference :: Maybe (Either Json String)
  }
  deriving (Eq, Show)

data Action = Create | Update | RemoveFile deriving (Eq, Show)

actionName :: Action -> String
actionName = \case
  Create -> "create"
  Update -> "update"
  RemoveFile -> "remove"

data Change = Change
  { changeAction :: Action,
    changeFile :: FilePath,
    changeRelative :: String,
    -- | The UTF-8 text to write. A plan holds every file of a run until
    -- it is applied, and a String costs several words a character, so
    -- plans keep bytes ('change' builds them fully).
    changeContent :: !B.ByteString,
    -- | What the file held when it was planned, as UTF-8 of its decoded
    -- text; 'Nothing' when absent.
    changeExpected :: !(Maybe B.ByteString)
  }
  deriving (Eq, Show)

-- | A change with its texts encoded now, so the plan does not keep them.
newChange :: Action -> FilePath -> String -> String -> Maybe String -> Change
newChange action file path' content expected =
  let encoded = utf8 content
      before = fmap utf8 expected
   in B.length encoded `seq` maybe () (`seq` ()) before `seq` Change action file path' encoded before

data AdapterUpdate = AdapterUpdate {adapterPath :: String, requiredAdapter :: String}
  deriving (Eq, Show)

data Plan = Plan
  { planRoot :: FilePath,
    planChanges :: [Change],
    planPreserved :: [String],
    planAdapterUpdates :: [AdapterUpdate]
  }
  deriving (Eq, Show)

-- | The SHA-256 of a text's UTF-8 bytes, in lower-case hex.
digestText :: String -> String
digestText = digestHex . digest . utf8

-- | The file's text, or 'Nothing' when it does not exist.
readOptional :: (Monad m) => FilePath -> Command m (Maybe String)
readOptional file =
  effectOr (ReadFile file) >>= \case
    Right bytes -> pure (Just (fromUtf8 bytes))
    Left (HostError NotFound _) -> pure Nothing
    Left problem -> abort (nodeFailure "open" file problem)

-- | readdir, or 'Nothing' when the directory does not exist; sorted.
readOptionalDirectory :: (Monad m) => FilePath -> Command m (Maybe [String])
readOptionalDirectory folder =
  effectOr (ListDirectory folder) >>= \case
    Right entries -> pure (Just (sortBy compareUtf16 (map entryName entries)))
    Left (HostError NotFound _) -> pure Nothing
    Left problem -> abort (nodeFailure "scandir" folder problem)

-- | files.mjs safePath: a relative output path that stays inside the root
-- and passes through no symbolic link.
safePath :: (Monad m) => FilePath -> String -> Command m FilePath
safePath root path'
  | null path' || isAbsolute path' || any (`elem` ["..", "."]) (splitSeparators path') =
      failWith ("Unsafe output path: " ++ path')
  | not (take (length prefix) resolved == prefix) = failWith ("Output escapes project: " ++ path')
  | otherwise = do
      effectOr (Stat Follow root) >>= \case
        Right status
          | statusKind status /= DirectoryKind -> failWith ("Output root is not a directory: " ++ root)
          | otherwise -> pure ()
        Left (HostError NotFound _) ->
          failWith ("Output root does not exist: " ++ root ++ ". Create it or initialize the target before generation.")
        Left problem -> abort (nodeFailure "stat" root problem)
      forM_ (scanl1 (\cursor part -> cursor ++ "/" ++ part) (splitOn '/' path')) $ \part -> do
        let cursor = join root part
        effectOr (Stat NoFollow cursor) >>= \case
          Right status | statusKind status == SymbolicLinkKind -> failWith ("Refusing symbolic-link output: " ++ path')
          Right _ -> pure ()
          Left (HostError NotFound _) -> pure ()
          Left problem -> abort (nodeFailure "lstat" cursor problem)
      pure resolved
  where
    resolved = resolve root path'
    prefix = resolve "/" root ++ "/"

splitSeparators :: String -> [String]
splitSeparators text = case break (`elem` ("/\\" :: String)) text of
  (part, []) -> [part]
  (part, _ : rest) -> part : splitSeparators rest

splitOn :: Char -> String -> [String]
splitOn separator text = case break (== separator) text of
  (part, []) -> [part]
  (part, _ : rest) -> part : splitOn separator rest

-- | files.mjs atomicWrite. The host's write is already a temporary sibling
-- and a rename, or, exclusively, a hard link that fails on an existing file;
-- it creates missing parents. files.mjs names its random temporary file in
-- an exclusive write's EEXIST message; this names the file.
atomicWrite :: (Monad m) => FilePath -> String -> Bool -> Command m ()
atomicWrite file content exclusive =
  effect
    (nodeFailure (if exclusive then "link" else "rename") file)
    (WriteFile (if exclusive then Effect.Create else Replace) Nothing file (utf8 content))

-- | The compiler's planned files.
artifactsFrom :: Json -> [Artifact]
artifactsFrom files =
  [ Artifact
      (maybe "" jsString (member "path" file))
      (maybe "" jsString (member "content" file))
      ( case member "ownership" file of
          Just (JString "generated") -> Generated
          Just (JString "user") -> User
          _ -> UnknownOwnership
      )
      ( case member "adapterReference" file of
          Nothing -> Nothing
          Just (JString text) -> Just (Right text)
          Just other -> Just (Left other)
      )
  | file <- maybe [] id (arrayOf files)
  ]

data Planning = Planning
  { seen :: S.Set String,
    changes :: [Change],
    preserved :: [String],
    adapterUpdates :: [AdapterUpdate],
    adapterHashes :: [(String, Json)],
    next :: [(String, Json)]
  }

-- | files.mjs planWrites. The predicate names generated files a mutation
-- run edited, which are kept as they are.
planWrites :: (Monad m) => FilePath -> [Artifact] -> String -> (FilePath -> Bool) -> Command m Plan
planWrites root artifacts manifest edited = do
  manifestPath <- safePath root manifest
  previousText <- readOptional manifestPath
  previous <- case previousText of
    Nothing -> pure (JObject [("version", integer 1), ("files", JObject [])])
    Just text -> either failWith pure (parseJson text)
  previousFiles <- case (member "version" previous, member "files" previous) of
    (Just (JNumber 1), Just files@(JObject _)) -> pure (members files)
    (Just (JNumber 1), Just files@(JArray _)) -> pure (members (indexed files))
    _ -> failWith "Invalid ownership manifest"
  let previousAdapters = maybe [] members (member "adapters" previous)
  planned <- foldM (visit previousFiles previousAdapters) (Planning S.empty [] [] [] [] []) artifacts
  removals <- fmap concat . forM previousFiles $ \(path', hash) ->
    if S.member path' (seen planned)
      then pure []
      else do
        file <- safePath root path'
        readOptional file >>= \case
          Nothing -> pure []
          Just old -> do
            when (JString (digestText old) /= hash) (failWith ("Refusing to remove edited generated file: " ++ path'))
            let removal = [newChange RemoveFile file path' "" (Just old)]
            forceList removal `seq` pure removal
  let manifestContent =
        stringify (JObject [("version", integer 1), ("files", jsObject (next planned)), ("adapters", jsObject (adapterHashes planned))]) ++ "\n"
      manifestChange =
        [ newChange (maybe Create (const Update) previousText) manifestPath manifest manifestContent previousText
        | Just manifestContent /= previousText
        ]
  pure (Plan root (changes planned ++ removals ++ manifestChange) (preserved planned) (adapterUpdates planned))
  where
    indexed (JArray items) = JObject [(show i, item) | (i, item) <- zip [0 :: Int ..] items]
    indexed other = other
    visit previousFiles previousAdapters state artifact = do
      let path' = artifactPath artifact
          content = artifactContent artifact
      when (S.member path' (seen state)) (failWith ("Duplicate output: " ++ path'))
      let state' = state {seen = S.insert path' (seen state)}
      file <- safePath root path'
      old <- readOptional file
      case artifactOwnership artifact of
        User -> do
          reference <- case artifactAdapterReference artifact of
            Just (Left _) -> failWith ("Invalid adapter reference: " ++ path')
            Just (Right text) -> pure text
            Nothing -> pure content
          let hash = digestText reference
              updated = old /= Nothing && lookup path' previousAdapters /= Just (JString hash)
              -- Built now, so the state keeps no reference to the content.
              updates = [AdapterUpdate path' content | updated]
              created = [newChange Create file path' content Nothing | old == Nothing]
          length hash `seq` forceList updates `seq` forceList created `seq`
            pure
              state'
                { adapterHashes = adapterHashes state' ++ [(path', JString hash)],
                  adapterUpdates = adapterUpdates state' ++ updates,
                  changes = changes state' ++ created,
                  preserved = preserved state' ++ [path' | old /= Nothing]
                }
        UnknownOwnership -> failWith "Unknown artifact ownership"
        Generated -> do
          let recorded = lookup path' previousFiles
          case (old, recorded) of
            (Just _, Just hash)
              | isTruthy hash && edited file -> pure state' {next = next state' ++ [(path', hash)]}
            _ -> do
              case old of
                Just text
                  | maybe True (not . isTruthy) recorded || recorded /= Just (JString (digestText text)) ->
                      failWith ("Refusing to overwrite unowned or edited generated file: " ++ path')
                _ -> pure ()
              let hash = digestText content
                  written = [newChange (maybe Create (const Update) old) file path' content old | old /= Just content]
              length hash `seq` forceList written `seq`
                pure
                  state'
                    { next = next state' ++ [(path', JString hash)],
                      changes = changes state' ++ written
                    }

-- | Each element to weak head normal form.
forceList :: [a] -> ()
forceList = foldr seq ()

-- | files.mjs applyWrites: recheck every planned file first, including
-- edits made since planning, then write.
applyWrites :: (Monad m) => [Plan] -> Command m ()
applyWrites plans = do
  forM_ plans $ \plan -> forM_ (planChanges plan) $ \change -> do
    _ <- safePath (planRoot plan) (changeRelative change)
    current <- readOptional (changeFile change)
    when (fmap utf8 current /= changeExpected change) (failWith ("File changed during generation: " ++ changeRelative change))
  forM_ plans $ \plan -> forM_ (planChanges plan) $ \change -> case changeAction change of
    RemoveFile -> effect (nodeFailure "unlink" (changeFile change)) (Remove NotRecursive (changeFile change))
    action ->
      effect
        (nodeFailure (if action == Create then "link" else "rename") (changeFile change))
        (WriteFile (if action == Create then Effect.Create else Replace) Nothing (changeFile change) (changeContent change))

-- | files.mjs collectSources: walk each entry (files, or directories in
-- sorted order), refuse symbolic links, keep .lawspec files, then read them
-- in sorted order with paths relative to @relativeTo@. The entries are what
-- the command line or a manifest declares, so they become readable.
collectSources :: (Monad m) => FilePath -> [String] -> FilePath -> Command m [(FilePath, String)]
collectSources root entries relativeTo = do
  grantRead (map (resolve root) entries)
  found <- concat <$> mapM (visit . resolve root) entries
  when (null found) (failWith "No .lawspec source files found")
  let files = sortBy compareUtf16 (S.toList (S.fromList found))
  forM files $ \file -> do
    bytes <- effect (nodeFailure "open" file) (ReadFile file)
    pure (relative relativeTo file, fromUtf8 bytes)
  where
    visit file = do
      status <- effect (nodeFailure "lstat" file) (Stat NoFollow file)
      case statusKind status of
        SymbolicLinkKind -> failWith ("Symbolic links are not supported in LawSpec sources: " ++ file)
        DirectoryKind -> do
          entries' <- effect (nodeFailure "scandir" file) (ListDirectory file)
          concat <$> mapM (visit . join file) (sortBy compareUtf16 (map entryName entries'))
        _ -> pure [file | ".lawspec" `isSuffixOf` file]

-- | JavaScript's default sort order: UTF-16 code units.
compareUtf16 :: String -> String -> Ordering
compareUtf16 left right = compare (concatMap units left) (concatMap units right)
  where
    units c
      | ord c < 0x10000 = [ord c]
      | otherwise = let v = ord c - 0x10000 in [0xD800 + v `div` 0x400, 0xDC00 + v `mod` 0x400]
