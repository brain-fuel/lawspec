-- Temporal propositions and performance budgets (law plane; see
-- docs/reference/language/temporal.md). Both are defined over the Clock
-- ability of lawspec.time, so they are sugar the parser expands into plain
-- expressions every target already compiles:
--
--   eventually within d, P   P is checked now, then after each of
--                            temporalPolls equal sleeps of the clock, until d
--                            has passed; true at the first check that holds
--   always within d, P       the same checks, each of which must hold
--   never within d, P        always within d, not P
--   e takes at most d        e is evaluated between two readings of the
--                            clock, and the time between them is at most d
--
-- A check is `if P then ... else ...`, which evaluates only the branch it
-- selects, so an eventually stops at the first check that holds. Under
-- `using virtual clock` each sleep moves the clock at once, so the checks are
-- deterministic. A budget is measured on the real clock only: the law that
-- holds one runs under Clock's production handler (LawSpec.Abilities), and
-- evidence reports it as measured (LawSpec.Discharge), never proved.
module LawSpec.Temporal
  ( Temporal(..), temporalPolls, temporalExpr, budgetExpr
  , budgetStart, isBudgetBinder, mentionsTemporal
  ) where

import Data.List (isInfixOf)
import LawSpec.Model

data Temporal = Eventually | Always deriving (Eq, Show)

-- How many sleeps a temporal proposition divides its span into: it checks
-- its proposition temporalPolls + 1 times.
temporalPolls :: Integer
temporalPolls = 20

-- A temporal proposition over a span of micros microseconds.
temporalExpr :: Temporal -> Integer -> Expr -> Expr
temporalExpr kind micros p
  | micros <= 0 = p
  | otherwise = go temporalPolls
  where
    step = max 1 (micros `div` temporalPolls)
    polls = min temporalPolls (micros `div` step)
    go k
      | k <= 0 || temporalPolls - k >= polls = p
      | otherwise =
          let later = sequenced (Apply (Var "sleep") (duration step)) (go (k - 1))
          in case kind of
               Eventually -> select p (BoolLit True) later
               Always -> select p later (BoolLit False)
    select c a b = foldl Apply (Var "prelude.select") [c, a, b]

-- e takes at most micros microseconds, on the clock.
budgetExpr :: Expr -> Integer -> Expr
budgetExpr e micros =
  bind budgetStart (Var "now") $
  bind "lawspecBudgetValue" e $
  bind "lawspecBudgetFinish" (Var "now") $
  Binary "<=" (Binary "-" (Var "lawspecBudgetFinish") (Var budgetStart)) (duration micros)

-- The binder that marks a budget, as far as Core: evidence reports a law
-- with one as measured.
budgetStart :: String
budgetStart = "lawspecBudgetStart"

isBudgetBinder :: String -> Bool
isBudgetBinder = (== budgetStart)

-- Whether a source writes a temporal proposition or a budget.
mentionsTemporal :: String -> Bool
mentionsTemporal text = any (`isInfixOf` text) ["eventually within", "always within", "never within", "takes at most"]

duration :: Integer -> Expr
duration micros = ConstructLit "Duration" [Number micros]

bind :: String -> Expr -> Expr -> Expr
bind name value body = MatchExpr value [MatchBranch letTag [name] body]

sequenced :: Expr -> Expr -> Expr
sequenced first rest = MatchExpr first [MatchBranch letTag ["lawspecIgnored"] rest]
