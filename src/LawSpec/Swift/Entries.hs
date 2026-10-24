-- | Where each declaration's entry is in Swift: the generated enum of its
-- unit. Definitions, abilities and tests call entries through this one
-- table. ref:DEC-typed-core-boundary
module LawSpec.Swift.Entries (Entry(..), entries, entryCall, orderedUnits, numbered) where

import qualified LawSpec.Core as C
import LawSpec.Swift.Code
import LawSpec.Swift.Names
import Data.Graph (stronglyConnComp, flattenSCC)

-- | Where a declaration's entry is: its unit's generated enum and the name.
data Entry = Entry { entryOwner :: String, entryName :: String }

-- Names in a unit's enum are its declarations' names, numbered when two
-- read alike (two specialised copies of one definition).
entries :: [C.Unit] -> [(C.Id, Entry)]
entries units =
  [ (C.declarationId d, Entry (generatedName (C.unitId u)) name)
  | u <- units, let ds = C.unitDeclarations u
  , (d, name) <- zip ds (numbered (map functionName ds)) ]

-- | Names made distinct in order: a repeat gains 2, 3, ...
numbered :: [String] -> [String]
numbered = go []
  where
    go _ [] = []
    go taken (n : rest) =
      let chosen = head [c | c <- n : [n ++ show k | k <- [2 :: Int ..]], c `notElem` taken]
      in chosen : go (chosen : taken) rest

entryCall :: Entry -> [Expr] -> Expr
entryCall e = Call (entryOwner e ++ "." ++ entryName e)

-- | The units in a stable order: each unit after the units it calls,
-- otherwise in the program's order (which follows imports). Units that call
-- each other keep the program's order.
orderedUnits :: [C.Unit] -> [C.Unit]
orderedUnits units = go [] units
  where
    deps u = [owner | identity <- calls u, Just owner <- [lookup identity owners], owner /= C.unitId u]
    cyclic = [C.unitId u | scc <- stronglyConnComp [(u, C.unitId u, deps u) | u <- units], length (flattenSCC scc) > 1, u <- flattenSCC scc]
    ready placed u = all (\d -> d `elem` placed || d `elem` cyclic && C.unitId u `elem` cyclic) (deps u)
    go _ [] = []
    go placed pending = case [u | u <- pending, ready (map C.unitId placed) u] of
      u : _ -> u : go (placed ++ [u]) [p | p <- pending, C.unitId p /= C.unitId u]
      [] -> pending
    owners = [(C.declarationId d, C.unitId u) | u <- units, d <- C.unitDeclarations u]
    calls u = concatMap (terms . C.definitionBody) (C.unitDefinitions u) ++
      concat [concatMap terms (C.contractExpressions c) | c <- C.unitContracts u]
    terms e = [i | C.ExternalCall i _ <- [C.expressionNode e]] ++ concatMap terms (C.children e)
