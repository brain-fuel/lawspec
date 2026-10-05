{-# OPTIONS_GHC -fno-cse -fno-full-laziness #-}
-- User-owned LawSpec adapter: a page-view counter with one replica per
-- thread. The adapters are pure, so they run their effects with
-- unsafePerformIO, each call its own effect.
module Example.Consistency (newViews, hit, total) where

import Control.Concurrent (myThreadId)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import qualified Data.Int as I
import qualified Data.Map.Strict as Map
import System.IO.Unsafe (unsafePerformIO)
import qualified LawSpecData as Data

-- Each counter's replicas, by thread.
{-# NOINLINE replicas #-}
replicas :: IORef (I.Int32, Map.Map I.Int32 (Map.Map String I.Int64))
replicas = unsafePerformIO (newIORef (0, Map.empty))

{-# NOINLINE newViews #-}
newViews :: () -> Data.Views
newViews () = unsafePerformIO $ atomicModifyIORef' replicas $ \(next, all') ->
  ((next + 1, Map.insert (next + 1) Map.empty all'), Data.Views (next + 1))

{-# NOINLINE hit #-}
hit :: Data.Views -> I.Int64
hit (Data.Views identity) = unsafePerformIO $ do
  me <- show <$> myThreadId
  atomicModifyIORef' replicas $ \(next, all') ->
    let own = Map.findWithDefault Map.empty identity all'
        count = Map.findWithDefault 0 me own + 1
    in ((next, Map.insert identity (Map.insert me count own) all'), count)

{-# NOINLINE total #-}
total :: Data.Views -> I.Int64
total (Data.Views identity) = unsafePerformIO $ do
  (_, all') <- readIORef replicas
  pure (sum (Map.elems (Map.findWithDefault Map.empty identity all')))
