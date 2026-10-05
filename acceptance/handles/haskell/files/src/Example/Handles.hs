{-# OPTIONS_GHC -fno-cse -fno-full-laziness #-}
-- User-owned LawSpec adapter: Jobs is a handle around an MVar-guarded
-- queue. The commands are sync, so each runs its effect with
-- unsafePerformIO, every call its own effect.
module Example.Handles (newJobs, submit, take, pending) where

import Prelude hiding (take)
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar, readMVar)
import qualified Data.Int as I
import Data.Sequence (Seq, ViewL(..), viewl, (|>))
import qualified Data.Sequence as Seq
import System.IO.Unsafe (unsafePerformIO)
import qualified LawSpecRuntime as LS

queue :: LS.Handle -> MVar (Seq I.Int32)
queue = LS.fromHandle

{-# NOINLINE newJobs #-}
newJobs :: () -> LS.Handle
newJobs () = unsafePerformIO (newMVar (Seq.empty :: Seq I.Int32) >>= LS.handle)

{-# NOINLINE submit #-}
submit :: LS.Handle -> I.Int32 -> ()
submit jobs job = unsafePerformIO (modifyMVar_ (queue jobs) (pure . (|> job)))

{-# NOINLINE take #-}
take :: LS.Handle -> Maybe I.Int32
take jobs = unsafePerformIO $ modifyMVar (queue jobs) $ \items -> pure $ case viewl items of
  EmptyL -> (items, Nothing)
  job :< rest -> (rest, Just job)

{-# NOINLINE pending #-}
pending :: LS.Handle -> I.Int32
pending jobs = unsafePerformIO (fromIntegral . Seq.length <$> readMVar (queue jobs))
