-- Names every target gives an ability's native pieces (see
-- docs/reference/language/handlers.md):
--
--   * the interface, named like the ability: Gateway;
--   * the production handler, written by hand (or bound in lawspec.json):
--     GatewayHandler;
--   * a spec handler's class, its name capitalized: fakeGateway is
--     FakeGateway;
--   * the recording transformer: GatewayRecording, wrapping any handler.
module LawSpec.AbilityNames
  ( interfaceName, productionName, specName, recordingName
  , unitAbilityPieces, handlerKeys, abilityOf, specHandlerOf, operationTypes
  ) where

import Data.Char (toUpper)
import qualified LawSpec.Core as C

capitalize :: String -> String
capitalize (c : cs) = toUpper c : cs
capitalize [] = []

interfaceName :: C.Ability -> String
interfaceName = C.abilityName

productionName :: C.Ability -> String
productionName a = C.abilityName a ++ "Handler"

specName :: C.Handler -> String
specName = capitalize . C.handlerName

recordingName :: C.Ability -> String
recordingName a = C.abilityName a ++ "Recording"

-- Whether a unit has anything for the ability emitters.
unitAbilityPieces :: C.Unit -> Bool
unitAbilityPieces u = not (null (C.unitAbilities u))

-- Every ability key a property installs a handler for.
handlerKeys :: C.Property -> [String]
handlerKeys p = [C.abilityKey a | (a, _) <- C.propertyHandlers p]

-- The ability a key names, among some units'.
abilityOf :: [C.Unit] -> C.AbilityRef -> Maybe C.Ability
abilityOf units ref = case [a | u <- units, a <- C.unitAbilities u, C.abilityId a == C.abilityRefId ref] of
  a : _ -> Just a
  [] -> Nothing

specHandlerOf :: [C.Unit] -> C.Id -> Maybe C.Handler
specHandlerOf units identity = case [h | u <- units, h <- C.unitHandlers u, C.handlerId h == identity] of
  h : _ -> Just h
  [] -> Nothing

-- An operation's parameter and result types.
operationTypes :: C.Ability -> String -> ([C.Type], C.Type)
operationTypes ability op = maybe ([], C.scalarType "Unit") C.functionType (lookup op (C.abilityOperations ability))
