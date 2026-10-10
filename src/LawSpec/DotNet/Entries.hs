-- | Where each declaration's entry is on .NET: the generated module of its
-- unit, named in F# and in C#. Definitions, abilities and tests call entries
-- through this one table. ref:DEC-typed-core-boundary
module LawSpec.DotNet.Entries (Entry(..), entries, entryCall, orderedUnits) where

import qualified LawSpec.Core as C
import LawSpec.DotNet.Code
import LawSpec.DotNet.Names
import Data.Graph (stronglyConnComp, flattenSCC)

-- | Where a declaration's entry is: its unit's generated module and the name.
data Entry = Entry { entryModule :: String, entryFs :: String, entryCs :: String }

entries :: [C.Unit] -> [(C.Id, Entry)]
entries units =
  [ (C.declarationId d, Entry (generatedModule (C.unitId u)) (functionName FSharp d) (functionName CSharp d))
  | u <- units, d <- C.unitDeclarations u ]

entryCall :: Entry -> [Expr] -> Expr
entryCall e = Call (Fn (entryModule e ++ "." ++ entryFs e) (shortModule (entryModule e) ++ "." ++ entryCs e))
  where shortModule m = m

-- | The units in an order F# compiles: a unit after the units its entries call.
-- A stable order: each unit after the units it calls, otherwise in the
-- program's order (which follows imports), so an adapter can call the
-- definitions of a unit its unit imports. Units that call each other keep
-- the program's order.
orderedUnits :: [C.Unit] -> [C.Unit]
orderedUnits units = go [] units
  where
    deps u = [owner | identity <- calls u, Just owner <- [lookup identity owners], owner /= C.unitId u]
    cyclic = [C.unitId u | scc <- stronglyConnComp [(u, C.unitId u, deps u) | u <- units], length (flattenSCC scc) > 1, u <- flattenSCC scc]
    ready placed u = all (\d -> d `elem` placed || d `elem` cyclic && C.unitId u `elem` cyclic) (deps u)
    go placed [] = []
    go placed pending = case [u | u <- pending, ready (map C.unitId placed) u] of
      u : _ -> u : go (placed ++ [u]) [p | p <- pending, C.unitId p /= C.unitId u]
      [] -> pending
    owners = [(C.declarationId d, C.unitId u) | u <- units, d <- C.unitDeclarations u]
    calls u = concatMap (terms . C.definitionBody) (C.unitDefinitions u) ++
      concat [concatMap terms (C.contractExpressions c) | c <- C.unitContracts u]
    terms e = [i | C.ExternalCall i _ <- [C.expressionNode e]] ++ concatMap terms (C.children e)

