{-# OPTIONS_GHC -fno-cse -fno-full-laziness #-}
-- Process-wide memo tables for the compiler's pure stages. A compiler kept
-- alive across requests (one wasm instance, the acceptance harness, an editor)
-- reuses the work for whatever did not change. Keys name their inputs
-- completely (see LawSpec.Dependencies), so a hit is indistinguishable from
-- recomputing, and entries for earlier versions of a program stay valid.
--
-- Each table has a weight budget and evicts its least recently used entries
-- beyond it, so memory stays bounded however many programs and targets one
-- process compiles. The WebAssembly build has a 32-bit heap.
module LawSpec.Memo (Table, newTable, memoized) where

import Control.Exception (evaluate)
import Data.IORef
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import System.IO.Unsafe (unsafePerformIO)

data Entry a = Entry { entryValue :: a, entryWeight :: !Int, entryStamp :: !Int }

data State a = State
  { entries :: !(M.Map T.Text (Entry a))
  , order :: !(M.Map Int T.Text)  -- stamp to key, least recently used first
  , total :: !Int
  , clock :: !Int
  }

data Table a = Table !Int (a -> Int) !(IORef (State a))

-- A table holding entries up to a total weight.
newTable :: Int -> (a -> Int) -> IO (Table a)
newTable budget weigh = Table budget weigh <$> newIORef (State M.empty M.empty 0 0)

memoized :: Table a -> String -> a -> a
memoized (Table budget weigh ref) key value = unsafePerformIO $ do
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
      computed <- evaluate value
      let weight = max 1 (weigh computed)
      atomicModifyIORef' ref $ \s ->
        if M.member k (entries s) then (s, ()) else
          (evict (s { entries = M.insert k (Entry computed weight (clock s)) (entries s)
                    , order = M.insert (clock s) k (order s)
                    , total = total s + weight
                    , clock = clock s + 1 }), ())
      pure computed
  where
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
