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
-- <directory>/<compiler version>/<table>/<key digest>; one that cannot be
-- read or decoded is recomputed and replaced.
module LawSpec.Memo (Table, newTable, newPersistentTable, memoized, withCacheDirectory) where

import Control.Exception (SomeException, evaluate, try)
import Data.Binary (Binary, decodeOrFail, encode)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.IORef
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import Data.Version (showVersion)
import System.Directory (createDirectoryIfMissing, renameFile)
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

-- | Pure callers get caching without threading state: the key names the inputs
-- completely, so returning a recorded value cannot change any result.
-- ref:DEC-incremental-compilation
memoized :: Table a -> String -> a -> a
memoized (Table budget weigh persistence ref) key value = unsafePerformIO $ do
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
              Just (d </> ("lawspec-" ++ showVersion version) </> name, digestHex (digestString key))
            _ -> Nothing
      stored <- maybe (pure Nothing) readStored file
      computed <- maybe (evaluate value) pure stored
      case (stored, file, persistence) of
        (Nothing, Just location, Just (Persistence _ encodeValue _)) -> writeStored location (encodeValue computed)
        _ -> pure ()
      let weight = max 1 (weigh computed)
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
    -- Drop the least recently used entries until the budget holds, keeping
    -- at least the newest.
    evict s
      | total s <= budget || M.size (entries s) <= 1 = s
      | otherwise = case M.minViewWithKey (order s) of
          Just ((_, oldest), rest) ->
            let w = maybe 0 entryWeight (M.lookup oldest (entries s))
            in evict s { entries = M.delete oldest (entries s), order = rest, total = total s - w }
          Nothing -> s
{-# NOINLINE memoized #-}
