{-# OPTIONS_GHC -fno-cse -fno-full-laziness #-}
-- Process-wide memo tables for the compiler's pure stages. A compiler kept
-- alive across requests (one wasm instance, the acceptance harness, an editor)
-- reuses the work for whatever did not change: the front end for unchanged
-- sources, each law's plan while the program's interface is unchanged, and
-- each unit's emitted files.
--
-- A table records entries under one interface at a time; entering another
-- interface drops them, so an entry is only ever returned for the inputs it
-- was computed from. Keys and interfaces are compared in full, never hashed.
-- The memoized functions are pure and deterministic, so a hit is
-- indistinguishable from recomputing.
module LawSpec.Memo (Table, newTable, scoped) where

import Control.Exception (evaluate)
import Data.IORef
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import System.IO.Unsafe (unsafePerformIO)

data State a = State
  { generation :: !Int, interface :: !T.Text, entries :: !(M.Map T.Text a) }

-- A table holds at most its limit of entries; a full table starts over.
data Table a = Table !Int !(IORef (State a))

newTable :: Int -> IO (Table a)
newTable limit = Table limit <$> newIORef (State 0 T.empty M.empty)

-- Enter an interface and memoize values by key under it. After another
-- interface is entered, the function computes without recording.
scoped :: Table a -> String -> (String -> a -> a)
scoped (Table limit ref) current = unsafePerformIO $ do
  let i = T.pack current
  g <- atomicModifyIORef' ref $ \s ->
    if generation s > 0 && interface s == i then (s, generation s)
    else let s' = State (generation s + 1) i M.empty in (s', generation s')
  pure (lookupOrRecord g)
  where
    lookupOrRecord g key value = unsafePerformIO $ do
      let k = T.pack key
      s <- readIORef ref
      if generation s /= g then pure value else case M.lookup k (entries s) of
        Just recorded -> pure recorded
        Nothing -> do
          computed <- evaluate value
          atomicModifyIORef' ref $ \s' -> if generation s' /= g then (s', ()) else
            (s' { entries = if M.size (entries s') >= limit then M.singleton k computed
                            else M.insert k computed (entries s') }, ())
          pure computed
    {-# NOINLINE lookupOrRecord #-}
{-# NOINLINE scoped #-}
