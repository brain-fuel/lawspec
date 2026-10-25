-- | Shared generation facts used by native harnesses and execution identities.
-- A result key must describe the budget the emitted generator actually uses.
-- ref:DEC-content-identity ref:DEC-incremental-compilation
module LawSpec.Testing.Budget (dataBudget, sharedNativeBudget) where

import LawSpec.Testing (PlannedProperty(..), Plan(..), PlannedUnit(..))
import qualified LawSpec.Core.Value as V

-- | Preserve the existing native generator budget, including its minimum and
-- its structural node count. It is intentionally shared across these targets.
dataBudget :: [PlannedProperty] -> Integer
dataBudget laws = maximum (64 : [valueNodes value | law <- laws, tuple <- boundaryCases law, value <- tuple])
  where
    valueNodes (V.DataValue _ _ fields) = 1 + sum (map valueNodes fields)
    valueNodes (V.PresenceValue _ payload) = 1 + maybe 0 valueNodes payload
    valueNodes _ = 1

sharedNativeBudget :: String -> Plan -> Maybe Integer
sharedNativeBudget target plan
  | target `elem` ["java","kotlin","scala","groovy","clojure","go","haskell"] =
      Just (dataBudget (concatMap plannedProperties (plannedUnits plan)))
  | otherwise = Nothing
