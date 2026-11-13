{-# OPTIONS_GHC -fno-cse -fno-full-laziness #-}

-- | Memo tables for the compiler's pure stages. A compiler kept alive across
-- requests (one wasm instance, the acceptance harness, an editor) reuses the
-- work for whatever did not change. Keys name their inputs completely (see
-- LawSpec.Dependencies), so a hit is indistinguishable from recomputing, and
-- entries for earlier versions of a program stay valid.
--
-- Each table has a weight budget and evicts its least recently used entries
-- beyond it, so memory stays bounded however many programs and targets one
-- process compiles. The WebAssembly build has a 32-bit heap.
--
-- A persistent table also keeps its entries on disk when a request names a
-- cache directory, so separate runs of the CLI share work. An entry is the
-- file <directory>/<table>/<key>, and a native compiler puts a folder
-- for its own build between the directory and the table code; one that
-- cannot be read or decoded is recomputed and replaced. Names are short
-- because Windows limits a whole path to 260 characters (see 'entryLocation').
-- The key digests the version, the table and the caller's key. A native
-- build is its executable's path, size and modification time: a compiler
-- rebuilt from changed sources (a checkout run in place) never reads what
-- another build wrote, so generation depends only on the program. The
-- WebAssembly host names a folder per build itself.
--
-- A request can also ask for progress: each stage's time on standard error,
-- as lines, as one line a terminal overwrites, or as a table when the
-- request ends (see 'staged').
module LawSpec.Memo (Table, CacheBackend (..), withCacheBackend, newTable, newPersistentTable, newTableByShow, newPersistentTableByShow, boundedShowWeight, memoized, memoizedState, withCacheDirectory, withRequest, withoutMemoization, buildIdentity, entryLocation, entryNameLength, temporaryName, CacheFailure (..), Progress (..), noProgress, staged) where

import Control.Exception (SomeException, bracket, displayException, evaluate, onException, try)
import Control.Monad (forM_, unless, when)
import qualified Control.Monad.Trans.State.Strict as Transition
import Data.Binary (Binary, decodeOrFail, encode)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.Bits (shiftR, (.&.))
import Data.IORef
import Data.List (foldl')
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import Data.Version (showVersion)
import Data.Word (Word64)
import LawSpec.Blake3 (blake3, hexOf)
import LawSpec.Digest (digestBytes, digestHex, digestString)
import Paths_lawspec (version)
import GHC.Clock (getMonotonicTimeNSec)
import System.CPUTime (getCPUTime)
import System.Directory (createDirectoryIfMissing, doesFileExist, getFileSize, getModificationTime, removeFile, renameFile)
import System.Environment (getExecutablePath, lookupEnv)
import System.FilePath ((</>))
import System.IO (hFlush, hPutStr, hPutStrLn, stderr)
import System.IO.Unsafe (unsafePerformIO)

-- | LAWSPEC_CACHE_TRACE=1 reports each table miss on standard error: the
-- table, whether the entry was read from disk, computed, or computed and too
-- heavy to keep, its weight and its CPU time.
cacheTrace :: IORef Bool
cacheTrace = unsafePerformIO (lookupEnv "LAWSPEC_CACHE_TRACE" >>= newIORef . maybe False (not . null))
{-# NOINLINE cacheTrace #-}

data Entry a = Entry {entryValue :: a, entryWeight :: !Int, entryStamp :: !Int}

data State a = State
  { entries :: !(M.Map T.Text (Entry a)),
    order :: !(M.Map Int T.Text), -- stamp to key, least recently used first
    total :: !Int,
    clock :: !Int
  }

-- | How a persistent table reads and writes its entries.
data Persistence a = Persistence String (a -> BL.ByteString) (BL.ByteString -> Maybe a)

-- | A bounded table, because a long-lived compiler (the language server, the
-- docs build) would otherwise keep every result it ever computed.
-- ref:DEC-incremental-compilation
data Table a = Table !Int (a -> Int) (Maybe (Persistence a)) !(IORef (State a))

-- | A table holding entries up to a total weight, in memory.
newTable :: Int -> (a -> Int) -> IO (Table a)
newTable budget weigh = Table budget weigh Nothing <$> newIORef (State M.empty M.empty 0 0)

-- | A table that also keeps its entries in the request's cache directory.
newPersistentTable :: (Binary a) => String -> Int -> (a -> Int) -> IO (Table a)
newPersistentTable name budget weigh =
  Table budget weigh (Just (Persistence name encode decoded)) <$> newIORef (State M.empty M.empty 0 0)
  where
    decoded bytes = case decodeOrFail bytes of
      Right (rest, _, value) | BL.null rest -> Just value
      _ -> Nothing

-- | The running compiler's build, beside its version: its executable's size
-- and modification time where it has one (none in WebAssembly, whose host
-- keeps a folder per build already).
buildIdentity :: String
buildIdentity = unsafePerformIO $ do
  found <-
    try
      ( do
          path <- getExecutablePath
          size <- getFileSize path
          modified <- getModificationTime path
          _ <- evaluate (length (show modified))
          pure ("-" ++ take 16 (digestHex (digestString (path ++ " " ++ show size ++ " " ++ show modified))))
      ) ::
      IO (Either SomeException String)
  pure (either (const "") id found)
{-# NOINLINE buildIdentity #-}

-- | Where an entry is kept: its folder and its file name. Windows refuses a
-- path longer than 260 characters unless long paths are enabled, and the
-- cache sits below a project that may itself be deep, so everything under the
-- cache directory is at most 54 characters: a 16-character folder for the
-- build, a 3-character folder for the table, and a 32-character name.
--
-- The name is 160 bits of the SHA-256 of the version, the table and the key,
-- in lower-case base 32 (no two names differ only by case). The table's
-- folder is the start of its name's digest. No two of today's tables share
-- one (the tests check), and entries would stay apart if two did, because
-- every name digests its table.
--
-- A native compiler adds the folder for its build ('buildIdentity'); the
-- WebAssembly compiler has none to add, and its host passes a directory per
-- build. ref:DEC-incremental-compilation
entryLocation :: FilePath -> String -> String -> (FilePath, FilePath)
entryLocation directory table key =
  ( (if null build then directory else directory </> build) </> take 3 (base32 (digestBytes (digestString table))),
    take entryNameLength (base32 (digestBytes (digestString (showVersion version ++ "\0" ++ table ++ "\0" ++ key))))
  )
  where
    build = drop 1 buildIdentity

-- | The length of an entry's file name.
entryNameLength :: Int
entryNameLength = 32

-- | An entry is written under this name and renamed. It is as long as the
-- entry's own name, so a path that fits the entry fits its temporary file,
-- and it cannot be an entry's name, which has no dot.
temporaryName :: FilePath -> FilePath
temporaryName name = take (length name - 2) name ++ ".t"

-- | RFC 4648 base 32 in lower case, without padding.
base32 :: B.ByteString -> String
base32 bytes = go (B.unpack bytes)
  where
    alphabet = "abcdefghijklmnopqrstuvwxyz234567"
    go [] = []
    go chunk =
      let (now, later) = splitAt 5 chunk
          value = foldl' (\acc byte -> acc * 256 + toInteger byte) 0 (take 5 (now ++ repeat 0)) :: Integer
          symbols = (length now * 8 + 4) `div` 5
       in [alphabet !! fromInteger ((value `shiftR` (5 * (7 - i))) .&. 31) | i <- [0 .. symbols - 1]] ++ go later

-- | A logical structural weight, bounded before expanding an entire value.
-- Layout documents may share alternative subdocuments: an unbounded Show (or
-- Binary) traversal can be exponential while the selected output stays small.
-- This observes at most budget+1 structural characters, identically on native
-- and WASM; runtime pointer sharing never affects an identity or cache value.
boundedShowWeight :: (Show a) => Int -> a -> Int
boundedShowWeight budget value = count 0 (show value)
  where
    limit = max 0 (min (maxBound - 1) budget)
    count size [] = size
    count size (_ : rest)
      | size >= limit = limit + 1
      | otherwise = count (size + 1) rest

-- | Preserve ordinary cache weights, without traversing oversized structures.
newTableByShow :: (Show a) => Int -> IO (Table a)
newTableByShow budget = newTable budget (boundedShowWeight budget)

newPersistentTableByShow :: (Binary a, Show a) => String -> Int -> IO (Table a)
newPersistentTableByShow name budget = newPersistentTable name budget (boundedShowWeight budget)

cacheDirectory :: IORef (Maybe FilePath)
cacheDirectory = unsafePerformIO (newIORef Nothing)
{-# NOINLINE cacheDirectory #-}

-- | A host can supply scoped persistence without giving the compiler ambient
-- filesystem authority. The cache encoding and admission rules stay here.
-- ref:DEC-host-sdk-independent-consumer
data CacheBackend = CacheBackend
  { cacheRead :: FilePath -> IO B.ByteString,
    cacheWrite :: FilePath -> BL.ByteString -> IO ()
  }

cacheBackend :: IORef (Maybe CacheBackend)
cacheBackend = unsafePerformIO (newIORef Nothing)
{-# NOINLINE cacheBackend #-}

-- | Scope a backend around a fully evaluated request; restore it even on failure.
-- Callers serialize requests on a compiler instance, as for cacheDirectory.
withCacheBackend :: Maybe CacheBackend -> IO a -> IO a
withCacheBackend backend =
  bracket
    (atomicModifyIORef' cacheBackend (\previous -> (backend, previous)))
    (writeIORef cacheBackend)
    . const

-- | Run a request with a cache directory (or none), forcing its result.
withCacheDirectory :: Maybe FilePath -> BL.ByteString -> BL.ByteString
withCacheDirectory directory result = fst (withRequest directory noProgress "" result)
{-# NOINLINE withCacheDirectory #-}

-- | The first entry a request could not store, and why. A cache that cannot
-- be written never changes a result, but a host that hides the reason leaves
-- every run cold (Windows refuses a path past 260 characters).
data CacheFailure = CacheFailure {failurePath :: FilePath, failureReason :: String}
  deriving (Eq, Show)

cacheFailure :: IORef (Maybe CacheFailure)
cacheFailure = unsafePerformIO (newIORef Nothing)
{-# NOINLINE cacheFailure #-}

-- | Run a request with its cache directory and progress reporting, forcing
-- its result. The title heads the timing table. Returns the first cache
-- write that failed, if any.
withRequest :: Maybe FilePath -> Progress -> String -> BL.ByteString -> (BL.ByteString, Maybe CacheFailure)
withRequest directory progress title result = unsafePerformIO $ do
  writeIORef cacheDirectory directory
  writeIORef cacheFailure Nothing
  writeIORef progressState (ProgressState progress [] [])
  started <- getMonotonicTimeNSec
  _ <- evaluate (BL.length result) `onException` (writeIORef cacheDirectory Nothing >> writeIORef progressState (ProgressState noProgress [] []))
  finished <- getMonotonicTimeNSec
  rows <- stageRows <$> readIORef progressState
  when (progressTerminal progress) (hPutStr stderr "\r\ESC[K" >> hFlush stderr)
  when (progressTimings progress) (hPutStr stderr (timingTable title (milliseconds (finished - started)) (reverse rows)) >> hFlush stderr)
  writeIORef progressState (ProgressState noProgress [] [])
  writeIORef cacheDirectory Nothing
  failed <- readIORef cacheFailure
  pure (result, failed)
{-# NOINLINE withRequest #-}

-- | What a request asked to see while it runs.
data Progress = Progress
  { -- | One line per finished stage: @lawspec-progress <stage> <ms> <label>@.
    progressLines :: Bool,
    -- | The running stage, on one line that a terminal overwrites.
    progressTerminal :: Bool,
    -- | A table of the stages when the request ends.
    progressTimings :: Bool
  }
  deriving (Eq, Show)

noProgress :: Progress
noProgress = Progress False False False

-- | A finished stage: its name, its label (a unit, a target, or nothing) and
-- the milliseconds it took, without the stages that ran inside it.
type StageRow = (String, String, Int)

data ProgressState = ProgressState
  { stageProgress :: !Progress,
    -- | Nanoseconds spent in the stages inside each running stage, innermost first.
    stageNested :: ![Word64],
    stageRows :: ![StageRow]
  }

progressState :: IORef ProgressState
progressState = unsafePerformIO (newIORef (ProgressState noProgress [] []))
{-# NOINLINE progressState #-}

milliseconds :: Word64 -> Int
milliseconds nanoseconds = fromIntegral ((nanoseconds + 500000) `div` 1000000)

-- | Name the stage that evaluating a value belongs to. The value is forced to
-- its outermost constructor, which its caller was about to do: for a stage
-- that returns Either, that decides success, so the stage's work is done.
-- What a stage leaves lazy is counted in the stage that first needs it. A
-- request that asked for no progress pays one IORef read.
staged :: String -> String -> a -> a
staged stage label value = unsafePerformIO $ do
  progress <- stageProgress <$> readIORef progressState
  if progress == noProgress
    then pure value
    else do
      when (progressTerminal progress) $ do
        hPutStr stderr ("\r\ESC[Klawspec: " ++ take 72 (stage ++ (if null label then "" else " " ++ label)))
        hFlush stderr
      modifyIORef' progressState (\s -> s {stageNested = 0 : stageNested s})
      started <- getMonotonicTimeNSec
      forced <- evaluate value
      finished <- getMonotonicTimeNSec
      let elapsed = finished - started
      inside <- atomicModifyIORef' progressState $ \s -> case stageNested s of
        own : outer : rest -> (s {stageNested = outer + elapsed : rest}, own)
        [own] -> (s {stageNested = []}, own)
        [] -> (s, 0)
      let own = milliseconds (elapsed - min elapsed inside)
      modifyIORef' progressState (\s -> s {stageRows = (stage, label, own) : stageRows s})
      when (progressLines progress) $
        hPutStrLn stderr (unwords (["lawspec-progress", stage, show own] ++ [label | not (null label)]))
      pure forced
{-# NOINLINE staged #-}

-- | The stages of one request, in the order each first ran, with the time of
-- every run of the same stage and label added up.
timingTable :: String -> Int -> [StageRow] -> String
timingTable title whole rows =
  unlines $
    ("lawspec timings: " ++ title ++ " (" ++ show whole ++ " ms)")
      : [ "  " ++ pad width name ++ "  " ++ padLeft 8 (show ms) ++ " ms" ++ (if runs > 1 then "  (" ++ show runs ++ " runs)" else "")
        | (name, (ms, runs)) <- summed
        ]
      ++ ["  " ++ pad width "(outside the stages above)" ++ "  " ++ padLeft 8 (show (max 0 (whole - sum [ms | (_, (ms, _)) <- summed]))) ++ " ms"]
  where
    named = [(stage ++ (if null label then "" else " " ++ label), ms) | (stage, label, ms) <- rows]
    totals = foldl' (\m (name, ms) -> M.insertWith (\(a, b) (c, d) -> (a + c, b + d)) name (ms, 1 :: Int) m) M.empty named
    summed = [(name, totals M.! name) | name <- firsts [] (map fst named)]
    firsts _ [] = []
    firsts seen (name : rest)
      | name `elem` seen = firsts seen rest
      | otherwise = name : firsts (name : seen) rest
    width = maximum (26 : map (length . fst) summed)
    pad n text = text ++ replicate (n - length text) ' '
    padLeft n text = replicate (n - length text) ' ' ++ text

memoizationEnabled :: IORef Bool
memoizationEnabled = unsafePerformIO (newIORef True)
{-# NOINLINE memoizationEnabled #-}

-- | A cold compiler baseline for cache correctness checks. Apply the function
-- inside the bracket, rather than accept an already evaluated cached result.
-- This changes no admission or verification step; it bypasses memo tables only.
withoutMemoization :: (a -> BL.ByteString) -> a -> BL.ByteString
withoutMemoization action input =
  unsafePerformIO $
    bracket
      (atomicModifyIORef' memoizationEnabled (\before -> (False, before)))
      (writeIORef memoizationEnabled)
      (\_ -> let result = action input in evaluate (BL.length result) >> pure result)
{-# NOINLINE withoutMemoization #-}

-- | A structured emission chunk may request helpers or literals while it is
-- lowered. Cache the full state transition, not just its document. Its
-- incoming serialized helper/name state is an exact presentation input;
-- the caller also supplies the checked dependency and native-context key.
-- There is no generated-text parsing in either direction.
memoizedState ::
  (Binary state) =>
  Table (Either String (value, state)) ->
  String ->
  Transition.StateT state (Either String) value ->
  Transition.StateT state (Either String) value
memoizedState table key action = Transition.StateT $ \before ->
  memoized
    table
    (key ++ ":state:" ++ hexOf (blake3 (BL.toStrict (encode before))))
    (Transition.runStateT action before)

-- | Pure callers get caching without threading state: the key names the inputs
-- completely, so returning a recorded value cannot change any result.
-- ref:DEC-incremental-compilation
memoized :: Table a -> String -> a -> a
memoized table key value = unsafePerformIO $ do
  enabled <- readIORef memoizationEnabled
  if enabled then memoizedIO table key value else evaluate value
{-# NOINLINE memoized #-}

memoizedIO :: Table a -> String -> a -> IO a
memoizedIO (Table budget weigh persistence ref) key value = do
  let k = T.pack key
  recorded <- atomicModifyIORef' ref $ \s -> case M.lookup k (entries s) of
    Just e ->
      let e' = e {entryStamp = clock s}
       in ( s
              { entries = M.insert k e' (entries s),
                order = M.insert (clock s) k (M.delete (entryStamp e) (order s)),
                clock = clock s + 1
              },
            Just (entryValue e)
          )
    Nothing -> (s, Nothing)
  case recorded of
    Just v -> pure v
    Nothing -> do
      directory <- readIORef cacheDirectory
      let file = case (directory, persistence) of
            (Just d, Just (Persistence name _ _)) -> Just (entryLocation d name key)
            _ -> Nothing
      stored <- maybe (pure Nothing) readStored file
      started <- getCPUTime
      computed <- maybe (evaluate value) pure stored
      -- Admission precedes serialization. Expanding a shared layout DAG
      -- just to persist an entry we cannot keep defeats the table's bound.
      weight <- evaluate (max 1 (weigh computed))
      finished <- getCPUTime
      traced <- readIORef cacheTrace
      let tableName = maybe "(memory)" (\(Persistence name _ _) -> name) persistence
          outcome
            | weight > budget = "over-budget"
            | Just _ <- stored = "disk"
            | otherwise = "computed"
      if traced
        then hPutStrLn stderr (unwords ["lawspec-cache", tableName, outcome, show weight, show ((finished - started) `div` 1000000000) ++ "ms"])
        else pure ()
      if weight > budget
        then pure computed
        else do
          case (stored, file, persistence) of
            (Nothing, Just location, Just (Persistence _ encodeValue _)) -> writeStored location (encodeValue computed)
            _ -> pure ()
          atomicModifyIORef' ref $ \s ->
            if M.member k (entries s)
              then (s, ())
              else
                ( evict
                    ( s
                        { entries = M.insert k (Entry computed weight (clock s)) (entries s),
                          order = M.insert (clock s) k (order s),
                          total = total s + weight,
                          clock = clock s + 1
                        }
                    ),
                  ()
                )
          pure computed
  where
    readStored (folder, name) = case persistence of
      Just (Persistence _ _ decodeValue) -> do
        backend <- readIORef cacheBackend
        bytes <- try (maybe B.readFile cacheRead backend (folder </> name)) :: IO (Either SomeException B.ByteString)
        pure (either (const Nothing) (decodeValue . BL.fromStrict) bytes)
      Nothing -> pure Nothing
    -- Written to a temporary name and renamed, so a reader never sees half an
    -- entry. A cache that cannot be written is skipped, and the request
    -- reports the first entry it could not write. Two compilers may write
    -- the same entry at once: the one whose rename finds the temporary file
    -- gone has lost to an identical entry, which is not a failure.
    writeStored (folder, name) bytes = do
      backend <- readIORef cacheBackend
      written <-
        try
          ( case backend of
              Just provider -> cacheWrite provider (folder </> name) bytes
              Nothing -> do
                createDirectoryIfMissing True folder
                BL.writeFile (folder </> temporaryName name) bytes
                renamed <- try (renameFile (folder </> temporaryName name) (folder </> name)) :: IO (Either SomeException ())
                forM_ (either Just (const Nothing) renamed) $ \problem -> do
                  present <- doesFileExist (folder </> name)
                  _ <- try (removeFile (folder </> temporaryName name)) :: IO (Either SomeException ())
                  unless present (ioError (userError (displayException problem)))
          ) ::
          IO (Either SomeException ())
      forM_ (either Just (const Nothing) written) $ \problem ->
        modifyIORef' cacheFailure (maybe (Just (CacheFailure (folder </> name) (displayException problem))) Just)
    -- Drop the least recently used entries until the budget holds.
    -- Each admitted entry individually fits the budget.
    evict s
      | total s <= budget || M.size (entries s) <= 1 = s
      | otherwise = case M.minViewWithKey (order s) of
          Just ((_, oldest), rest) ->
            let w = maybe 0 entryWeight (M.lookup oldest (entries s))
             in evict s {entries = M.delete oldest (entries s), order = rest, total = total s - w}
          Nothing -> s
