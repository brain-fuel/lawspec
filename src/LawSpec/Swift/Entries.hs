-- | Where each declaration's entry is in Swift: the generated enum of its
-- unit. Definitions, abilities and tests call entries through this one
-- table. ref:DEC-typed-core-boundary
module LawSpec.Swift.Entries (Entry(..), entries, entryCall, orderedUnits) where

import qualified LawSpec.Core as C
import LawSpec.Swift.Code
import LawSpec.Swift.Names
import Data.Graph (stronglyConnComp, flattenSCC)

-- | Where a declaration's entry is: its unit's generated enum and the name.
data Entry = Entry { entryOwner :: String, entryName :: String }

entries :: [C.Unit] -> [(C.Id, Entry)]
entries units =
  [ (C.declarationId d, Entry (generatedName (C.unitId u)) (functionName d))
  | u <- units, d <- C.unitDeclarations u ]

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
