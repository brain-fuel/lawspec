-- Paths of the Rust pieces of abilities (LawSpec.AbilityEmit.Rust), which
-- the definitions and tests call: an operation's bridge, a spec handler's
-- struct and an ability's trait, from the crate root.
module LawSpec.RustAbilityPaths (moduleOf, moduleOfName, foreignOwners, performBridges, bridgeName, traitPath, mappedFailures) where

import Data.Char (isAlphaNum)
import qualified LawSpec.Core as C
import LawSpec.AbilityNames

-- A unit's module in lawspec_abilities.
moduleOf :: C.Unit -> String
moduleOf = moduleOfName . C.idText . C.unitId

moduleOfName :: String -> String
moduleOfName = map (\c -> if isAlphaNum c || c == '_' then c else '_')

-- The units whose abilities a unit imports: a test mounts their adapter
-- modules, which hold the production handlers.
foreignOwners :: C.Unit -> [String]
foreignOwners u = foldr (\x acc -> if x `elem` acc then acc else x : acc) []
  [ownerName a | a <- C.unitAbilities u, ownerName a /= C.idText (C.unitId u)]

-- The bridge of each operation of each unit: the identity Core calls it by
-- and its path from the crate root.
performBridges :: [C.Unit] -> [(C.Id, String)]
performBridges units =
  [ (C.operationId (C.Operation (C.abilityInstance a) op), "lawspec_abilities::" ++ moduleOf u ++ "::perform_" ++ bridgeName a op)
  | u <- units, a <- ownAbilities u, (op, _) <- C.abilityOperations a ] ++
  -- handle ... with h end makes h with its struct's new, as its ability's trait.
  [ (C.Id ("handler:" ++ C.idText (C.handlerId h)), "lawspec_abilities::" ++ moduleOf u ++ "::" ++ specName h)
  | u <- units, h <- C.unitHandlers u ] ++
  [ (C.Id ("trait:" ++ C.abilityKey (C.abilityInstance a)), traitPath units (C.abilityInstance a))
  | u <- units, a <- ownAbilities u ]

-- An operation's bridge function: perform_<op>, or for a parameterized
-- ability's instance, perform_<Instance>_<op>.
bridgeName :: C.Ability -> String -> String
bridgeName a op = if null (C.abilityArguments a) then op else interfaceName a ++ "_" ++ op

-- The panic payloads lawspec.json maps to failures of this type, as the
-- last argument of ls::native_failures: each payload type T becomes its
-- constructor, given T's Debug text when the constructor takes a message.
mappedFailures :: Maybe String -> [C.FailureBinding] -> C.Type -> String
mappedFailures library bindings failure = "vec![" ++ concat
  [ "Box::new(|payload: &(dyn std::any::Any + Send)| payload.downcast_ref::<" ++ path (C.failureNative b) ++ ">().map(|error| " ++
    "ls::construct_data(" ++ show (C.idText (C.failureConstructor b)) ++ ", vec![" ++
    (if C.failureMessage b then "ls::Value::Text(format!(\"{error:?}\"))" else "") ++ "]))) as ls::MappedFailure, "
  | b <- bindings, C.failureType b == failure ] ++ "]"
  where path parts = concatMap (\(i, p) -> (if i > (0 :: Int) then "::" else "") ++ (if i == 0 && p == "crate" then maybe p id library else p)) (zip [0 ..] parts)

-- The trait of an ability, from the crate root.
traitPath :: [C.Unit] -> C.AbilityRef -> String
traitPath units ref = case C.findAbility units ref of
  Just (_, a) -> "lawspec_abilities::" ++ moduleOfName (ownerName a) ++ "::" ++ interfaceName a
  Nothing -> "dyn std::any::Any"

