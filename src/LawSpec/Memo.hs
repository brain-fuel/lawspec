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
-- cache directory, so separate runs of the CLI share work. Entries live under
-- <directory>/<compiler build>/<table>/<key digest>; one that cannot be
-- read or decoded is recomputed and replaced. The build is the version and,
-- for a native compiler, its executable's size and modification time: a
-- compiler rebuilt from changed sources (a checkout run in place) never
-- reads what another build wrote, so generation depends only on the program.
module LawSpec.Memo (Table, newTable, newPersistentTable, newTableByShow, newPersistentTableByShow, boundedShowWeight, memoized, memoizedState, withCacheDirectory, withoutMemoization, buildIdentity) where

import qualified Control.Monad.Trans.State.Strict as Transition
import LawSpec.Blake3 (blake3, hexOf)
import Control.Exception (SomeException, evaluate, try, bracket)
import Data.Binary (Binary, decodeOrFail, encode)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.IORef
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import Data.Version (showVersion)
import System.Directory (createDirectoryIfMissing, renameFile, getFileSize, getModificationTime)
import System.Environment (getExecutablePath)
import System.FilePath ((</>))
import System.IO.Unsafe (unsafePerformIO)
import LawSpec.Digest (digestHex, digestString)
import Paths_lawspec (version)

data Entry a = Entry { entryValue :: a, entryWeight :: !Int, entryStamp :: !Int }

data State a = State
  { entries :: !(M.Map T.Text (Entry a))
  , order :: !(M.Map Int T.Text)  -- stamp to key, least recently used first
  , total :: !Int
  , clock :: !Int
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
newPersistentTable :: Binary a => String -> Int -> (a -> Int) -> IO (Table a)
newPersistentTable name budget weigh =
  Table budget weigh (Just (Persistence name encode decoded)) <$> newIORef (State M.empty M.empty 0 0)
  where decoded bytes = case decodeOrFail bytes of
          Right (rest, _, value) | BL.null rest -> Just value
          _ -> Nothing

-- | The running compiler's build, beside its version: its executable's size
-- and modification time where it has one (none in WebAssembly, whose host
-- keeps a folder per build already).
buildIdentity :: String
buildIdentity = unsafePerformIO $ do
  found <- try (do
    path <- getExecutablePath
    size <- getFileSize path
    modified <- getModificationTime path
    _ <- evaluate (length (show modified))
    pure ("-" ++ take 16 (digestHex (digestString (path ++ " " ++ show size ++ " " ++ show modified))))) :: IO (Either SomeException String)
  pure (either (const "") id found)
{-# NOINLINE buildIdentity #-}

-- | A logical structural weight, bounded before expanding an entire value.
-- Layout documents may share alternative subdocuments: an unbounded Show (or
-- Binary) traversal can be exponential while the selected output stays small.
-- This observes at most budget+1 structural characters, identically on native
-- and WASM; runtime pointer sharing never affects an identity or cache value.
boundedShowWeight :: Show a => Int -> a -> Int
boundedShowWeight budget value = count 0 (show value)
  where
    limit = max 0 (min (maxBound - 1) budget)
    count size [] = size
    count size (_ : rest)
      | size >= limit = limit + 1
      | otherwise = count (size + 1) rest

-- | Preserve ordinary cache weights, without traversing oversized structures.
newTableByShow :: Show a => Int -> IO (Table a)
newTableByShow budget = newTable budget (boundedShowWeight budget)

newPersistentTableByShow :: (Binary a, Show a) => String -> Int -> IO (Table a)
newPersistentTableByShow name budget = newPersistentTable name budget (boundedShowWeight budget)

cacheDirectory :: IORef (Maybe FilePath)
cacheDirectory = unsafePerformIO (newIORef Nothing)
{-# NOINLINE cacheDirectory #-}

-- | Run a request with a cache directory (or none), forcing its result.
withCacheDirectory :: Maybe FilePath -> BL.ByteString -> BL.ByteString
withCacheDirectory directory result = unsafePerformIO $ do
  writeIORef cacheDirectory directory
  _ <- evaluate (BL.length result)
  writeIORef cacheDirectory Nothing
  pure result
{-# NOINLINE withCacheDirectory #-}

memoizationEnabled :: IORef Bool
memoizationEnabled = unsafePerformIO (newIORef True)
{-# NOINLINE memoizationEnabled #-}

-- | A cold compiler baseline for cache correctness checks. Apply the function
-- inside the bracket, rather than accept an already evaluated cached result.
-- This changes no admission or verification step; it bypasses memo tables only.
withoutMemoization :: (a -> BL.ByteString) -> a -> BL.ByteString
withoutMemoization action input = unsafePerformIO $ bracket
  (atomicModifyIORef' memoizationEnabled (\before -> (False,before)))
  (writeIORef memoizationEnabled)
  (\_ -> let result = action input in evaluate (BL.length result) >> pure result)
{-# NOINLINE withoutMemoization #-}

-- | A structured emission chunk may request helpers or literals while it is
-- lowered. Cache the full state transition, not just its document. Its
-- incoming serialized helper/name state is an exact presentation input;
-- the caller also supplies the checked dependency and native-context key.
-- There is no generated-text parsing in either direction.
memoizedState :: Binary state => Table (Either String (value, state)) -> String
  -> Transition.StateT state (Either String) value -> Transition.StateT state (Either String) value
memoizedState table key action = Transition.StateT $ \before ->
  memoized table (key ++ ":state:" ++ hexOf (blake3 (BL.toStrict (encode before))))
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
      let e' = e { entryStamp = clock s }
      in (s { entries = M.insert k e' (entries s)
            , order = M.insert (clock s) k (M.delete (entryStamp e) (order s))
            , clock = clock s + 1 }, Just (entryValue e))
    Nothing -> (s, Nothing)
  case recorded of
    Just v -> pure v
    Nothing -> do
      directory <- readIORef cacheDirectory
      let file = case (directory, persistence) of
            (Just d, Just (Persistence name _ _)) ->
              Just (d </> ("lawspec-" ++ showVersion version ++ buildIdentity) </> name, digestHex (digestString key))
            _ -> Nothing
      stored <- maybe (pure Nothing) readStored file
      computed <- maybe (evaluate value) pure stored
      -- Admission precedes serialization. Expanding a shared layout DAG
      -- just to persist an entry we cannot keep defeats the table's bound.
      weight <- evaluate (max 1 (weigh computed))
      if weight > budget then pure computed else do
        case (stored, file, persistence) of
          (Nothing, Just location, Just (Persistence _ encodeValue _)) -> writeStored location (encodeValue computed)
          _ -> pure ()
        atomicModifyIORef' ref $ \s ->
          if M.member k (entries s) then (s, ()) else
            (evict (s { entries = M.insert k (Entry computed weight (clock s)) (entries s)
                      , order = M.insert (clock s) k (order s)
                      , total = total s + weight
                      , clock = clock s + 1 }), ())
        pure computed
  where
    readStored (folder, name) = case persistence of
      Just (Persistence _ _ decodeValue) -> do
        bytes <- try (B.readFile (folder </> name)) :: IO (Either SomeException B.ByteString)
        pure (either (const Nothing) (decodeValue . BL.fromStrict) bytes)
      Nothing -> pure Nothing
    -- Written to a temporary name and renamed, so a reader never sees half an
    -- entry. A cache that cannot be written is skipped.
    writeStored (folder, name) bytes = do
      _ <- try (do
        createDirectoryIfMissing True folder
        BL.writeFile (folder </> (name ++ ".tmp")) bytes
        renameFile (folder </> (name ++ ".tmp")) (folder </> name)) :: IO (Either SomeException ())
      pure ()
    -- Drop the least recently used entries until the budget holds.
    -- Each admitted entry individually fits the budget.
    evict s
      | total s <= budget || M.size (entries s) <= 1 = s
      | otherwise = case M.minViewWithKey (order s) of
          Just ((_, oldest), rest) ->
            let w = maybe 0 entryWeight (M.lookup oldest (entries s))
            in evict s { entries = M.delete oldest (entries s), order = rest, total = total s - w }
          Nothing -> s
