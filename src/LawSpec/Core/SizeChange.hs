-- | Size-change termination (Lee, Jones and Ben-Amram, "The size-change
-- principle for program termination", POPL 2001), as Idris 2 and Agda apply
-- it to mutually recursive definitions.
--
-- Each call records how some measure of the callee's arguments relates to a
-- measure of the caller's parameters: strictly smaller, or no larger. The
-- relations of a call path compose. A program terminates when every call
-- path from a definition back to itself that composes to itself (an
-- idempotent loop) keeps one measure and strictly decreases it: an infinite
-- run would otherwise decrease a well-founded measure for ever.
--
-- This module only closes and inspects the relations. Establishing that a
-- measure is well founded and that an argument is smaller is the caller's
-- obligation (LawSpec.Core.Totality). Nothing here is assumed of the nodes.
-- ref:DEC-size-change-termination
module LawSpec.Core.SizeChange (Relation, Verdict (..), sizeChange) where

import qualified Data.Map.Strict as M
import qualified Data.Set as S

-- | From a caller's measure to a callee's measure: True when the callee's is
-- strictly smaller, False when it is no larger. An absent pair is unknown.
type Relation = M.Map (Int, Int) Bool

data Verdict node
  = Terminates
  -- | A loop on this node, by the nodes its calls pass through, on which no
  -- measure is both kept and strictly decreased.
  | Loops node [node]
  -- | The closure passed the given number of composed relations. The
  -- analysis is then incomplete; it has not shown a loop.
  | Exhausted
  deriving (Eq, Show)

compose :: Relation -> Relation -> Relation
compose first second =
  M.fromListWith
    (||)
    [ ((from, to), strict || later)
    | ((from, middle), strict) <- M.toList first,
      ((middle', to), later) <- M.toList second,
      middle == middle'
    ]

-- | Close the calls under composition, keeping one witness path for each
-- distinct relation between two nodes, and look for a loop that cannot
-- decrease. The limit bounds the number of distinct composed relations.
sizeChange :: (Ord node) => Int -> [(node, node, Relation)] -> Verdict node
sizeChange limit calls = close initial (M.toList initial)
  where
    initial = M.fromList [((from, to, relation), [to]) | (from, to, relation) <- calls]
    close known [] = case failing known of
      (node, path) : _ -> Loops node path
      [] -> Terminates
    close known (((from, to, relation), path) : pending)
      | M.size known > limit = Exhausted
      | otherwise =
          let after =
                [ ((from, next, compose relation other), path ++ rest)
                | ((start, next, other), rest) <- M.toList known,
                  start == to
                ]
              before =
                [ ((previous, to, compose other relation), rest ++ path)
                | ((previous, end, other), rest) <- M.toList known,
                  end == from
                ]
              fresh = M.toList (M.fromList (after ++ before) `M.difference` known)
           in close (foldr (uncurry M.insert) known fresh) (pending ++ fresh)
    failing known =
      [ (from, path)
      | ((from, to, relation), path) <- M.toList known,
        from == to,
        compose relation relation == relation,
        not (or [strict | ((measure, same), strict) <- M.toList relation, measure == same])
      ]
