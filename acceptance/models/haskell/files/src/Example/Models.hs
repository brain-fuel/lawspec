{-# OPTIONS_GHC -fno-cse -fno-full-laziness #-}
-- User-owned LawSpec adapter: a stack and an atomic counter. The counter's
-- commands change shared state, so they run their effects with
-- unsafePerformIO; each call is its own effect.
module Example.Models (empty, push, pop, peek, newCounter, increment, decrement, read) where

import Prelude hiding (read)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import qualified Data.Int as I
import qualified Data.Map.Strict as Map
import System.IO.Unsafe (unsafePerformIO)
import qualified LawSpecData as Data

{-# NOINLINE counters #-}
counters :: IORef (I.Int32, Map.Map I.Int32 I.Int64)
counters = unsafePerformIO (newIORef (0, Map.empty))

empty :: () -> Data.Stack
empty _ = Data.StackEmpty

push :: I.Int8 -> Data.Stack -> Data.PushFlow
push top rest = Data.PushFlow (Data.StackPush top rest)

-- The flow signature guarantees a nonempty stack.
pop :: Data.Stack -> Data.PopFlow
pop (Data.StackPush top rest) = Data.PopFlow top rest
pop Data.StackEmpty = error "pop needs a nonempty stack"

peek :: Data.Stack -> Data.PeekFlow
peek stack@(Data.StackPush top _) = Data.PeekFlow top stack
peek Data.StackEmpty = error "peek needs a nonempty stack"

{-# NOINLINE newCounter #-}
newCounter :: () -> Data.Counter
newCounter () = unsafePerformIO $ atomicModifyIORef' counters $ \(next, counts) ->
  ((next + 1, Map.insert (next + 1) 0 counts), Data.Counter (next + 1))

-- Changes a counter atomically.
{-# NOINLINE change #-}
change :: I.Int64 -> Data.Counter -> I.Int64
change by (Data.Counter identity) = unsafePerformIO $ atomicModifyIORef' counters $ \(next, counts) ->
  let count = Map.findWithDefault 0 identity counts + by
  in ((next, Map.insert identity count counts), count)

increment :: Data.Counter -> I.Int64
increment = change 1

decrement :: Data.Counter -> I.Int64
decrement = change (-1)

read :: Data.Counter -> I.Int64
read = change 0
