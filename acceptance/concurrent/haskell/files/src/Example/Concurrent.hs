{-# OPTIONS_GHC -fno-cse -fno-full-laziness #-}
-- User-owned LawSpec adapter: a queue, a set and a map shared between
-- threads, each guarded by its own MVar. The start commands are sync, so
-- they run their effect with unsafePerformIO, each call its own effect.
module Example.Concurrent
  ( newQueue, offer, poll, queueSize
  , newTags, tag, untag, tagged
  , newCache, store, fetch, evict
  ) where

import Control.Concurrent.MVar (MVar, modifyMVar, newMVar, readMVar)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import qualified Data.Int as I
import qualified Data.Map.Strict as Map
import Data.Sequence (Seq, ViewL(..), viewl, (|>))
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import System.IO.Unsafe (unsafePerformIO)
import qualified LawSpecData as Data

-- | Structures by handle id, and the next id to hand out.
type Registry a = IORef (I.Int32, Map.Map I.Int32 (MVar a))

{-# NOINLINE queues #-}
queues :: Registry (Seq I.Int32)
queues = unsafePerformIO (newIORef (0, Map.empty))

{-# NOINLINE sets #-}
sets :: Registry (Set.Set I.Int32)
sets = unsafePerformIO (newIORef (0, Map.empty))

{-# NOINLINE maps #-}
maps :: Registry (Map.Map I.Int8 I.Int64)
maps = unsafePerformIO (newIORef (0, Map.empty))

-- | A new structure under a fresh id.
new :: Registry a -> a -> IO I.Int32
new registry value = do
  box <- newMVar value
  atomicModifyIORef' registry $ \(next, boxes) -> ((next + 1, Map.insert next box boxes), next)

-- | A structure by its handle; generated tests may name one first.
get :: Registry a -> I.Int32 -> a -> IO (MVar a)
get registry identity empty = do
  fresh <- newMVar empty
  atomicModifyIORef' registry $ \(next, boxes) -> case Map.lookup identity boxes of
    Just box -> ((next, boxes), box)
    Nothing -> ((next, Map.insert identity fresh boxes), fresh)

-- | Changes a structure atomically, returning a result.
with :: Registry a -> I.Int32 -> a -> (a -> (a, b)) -> IO b
with registry identity empty change = do
  box <- get registry identity empty
  modifyMVar box (pure . change)

{-# NOINLINE newQueue #-}
newQueue :: () -> Data.WorkQueue
newQueue () = unsafePerformIO (Data.WorkQueue <$> new queues Seq.empty)

offer :: Data.WorkQueue -> I.Int32 -> IO ()
offer (Data.WorkQueue identity) value = with queues identity Seq.empty $ \items -> (items |> value, ())

poll :: Data.WorkQueue -> IO (Maybe I.Int32)
poll (Data.WorkQueue identity) = with queues identity Seq.empty $ \items -> case viewl items of
  front :< rest -> (rest, Just front)
  EmptyL -> (items, Nothing)

queueSize :: Data.WorkQueue -> IO I.Int64
queueSize (Data.WorkQueue identity) = do
  box <- get queues identity Seq.empty
  fromIntegral . Seq.length <$> readMVar box

{-# NOINLINE newTags #-}
newTags :: () -> Data.Tags
newTags () = unsafePerformIO (Data.Tags <$> new sets Set.empty)

tag :: Data.Tags -> I.Int32 -> IO Bool
tag (Data.Tags identity) value = with sets identity Set.empty $ \items ->
  let added = not (Set.member value items)
  in (Set.insert value items, added)

untag :: Data.Tags -> I.Int32 -> IO Bool
untag (Data.Tags identity) value = with sets identity Set.empty $ \items ->
  (Set.delete value items, Set.member value items)

tagged :: Data.Tags -> I.Int32 -> IO Bool
tagged (Data.Tags identity) value = do
  box <- get sets identity Set.empty
  Set.member value <$> readMVar box

{-# NOINLINE newCache #-}
newCache :: () -> Data.Cache
newCache () = unsafePerformIO (Data.Cache <$> new maps Map.empty)

store :: Data.Cache -> I.Int8 -> I.Int64 -> IO (Maybe I.Int64)
store (Data.Cache identity) key value = with maps identity Map.empty $ \entries ->
  let previous = Map.lookup key entries
  in (Map.insert key value entries, previous)

fetch :: Data.Cache -> I.Int8 -> IO (Maybe I.Int64)
fetch (Data.Cache identity) key = do
  box <- get maps identity Map.empty
  Map.lookup key <$> readMVar box

evict :: Data.Cache -> I.Int8 -> IO (Maybe I.Int64)
evict (Data.Cache identity) key = with maps identity Map.empty $ \entries ->
  (Map.delete key entries, Map.lookup key entries)
