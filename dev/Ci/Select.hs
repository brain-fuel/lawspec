-- | Which steps a run of lawspec-dev ci executes: by name (--only) or by
-- what changed (--affected). Both keep the steps a selected step must follow,
-- since a suite without its bootstrap or the current harness checks nothing.
--
-- This module is pure; dev/Ci.hs declares what each step reads and asks git
-- what changed.
module Ci.Select (Reads(..), reading, also, matches, withPrerequisites, affected) where

import Data.List (isPrefixOf)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

-- | The repository files a step reads, by their paths from the root.
newtype Reads = Reads {readsFile :: FilePath -> Bool}

-- | The files under a kept root (an empty list keeps every file) that are
-- not under a dropped root. A root is a path prefix.
reading :: [FilePath] -> [FilePath] -> Reads
reading keep dropped = Reads $ \file ->
  (null keep || any (`isPrefixOf` file) keep) && not (any (`isPrefixOf` file) dropped)

-- | Further files, whatever the roots say.
also :: (FilePath -> Bool) -> Reads -> Reads
also extra (Reads declared) = Reads (\file -> extra file || declared file)

-- | A shell-style pattern over a step name: * is any run of characters and ?
-- any one character. Nothing else is special.
matches :: String -> String -> Bool
matches pattern' name = case (pattern', name) of
  ([], []) -> True
  ('*' : rest, _) -> matches rest name || (not (null name) && matches pattern' (drop 1 name))
  ('?' : rest, _ : more) -> matches rest more
  (p : rest, c : more) -> p /= '*' && p /= '?' && p == c && matches rest more
  _ -> False

-- | The selected steps with every step they follow, directly or not. A name
-- the run does not contain is ignored, as the scheduler ignores it.
withPrerequisites :: [(String, [String])] -> S.Set String -> S.Set String
withPrerequisites follows = go S.empty . S.toList
  where
    after = M.fromList follows
    go seen [] = seen
    go seen (name : rest)
      | name `S.member` seen || not (name `M.member` after) = go seen rest
      | otherwise = go (S.insert name seen) (M.findWithDefault [] name after ++ rest)

-- | The steps a change affects: those that read a changed file, and those
-- that declare nothing, which may read anything. No change affects no step.
affected :: [FilePath] -> [(String, Maybe Reads)] -> S.Set String
affected changed steps = S.fromList
  [ name | not (null changed), (name, declared) <- steps
  , maybe True (\reads' -> any (readsFile reads') changed) declared ]
