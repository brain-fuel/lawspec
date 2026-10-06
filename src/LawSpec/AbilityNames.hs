-- Names every target gives an ability's native pieces (see
-- docs/reference/language/handlers.md):
--
--   * the interface, named like the ability: Gateway;
--   * the production handler, written by hand (or bound in lawspec.json):
--     GatewayHandler;
--   * a spec handler's class, its name capitalized: fakeGateway is
--     FakeGateway;
--   * the recording transformer: GatewayRecording, wrapping any handler.
--
-- A parameterized ability's pieces are named for each type it is used at:
-- Store Int32 is StoreInt32, StoreInt32Handler and StoreInt32Recording.
--
-- The unit that declares an ability owns its interface, production handler
-- and recording (ownedAbilityUnits), so every unit that imports it shares
-- them; a spec handler belongs to the unit that declares it.
module LawSpec.AbilityNames
  ( interfaceName, productionName, specName, recordingName
  , unitAbilityPieces, handlerKeys, abilityOf, specHandlerOf, operationTypes
  , ownedAbilityUnits, abilityHome, typeWord, ownAbilities, ownerName, unitAbility, displayName, fieldName
  ) where

import Data.Char (toUpper)
import qualified LawSpec.Core as C

capitalize :: String -> String
capitalize (c : cs) = toUpper c : cs
capitalize [] = []

interfaceName :: C.Ability -> String
interfaceName a = C.abilityName a ++ concatMap typeWord (C.abilityArguments a)

-- An operation as a field of its ability's record, in targets whose
-- records share one namespace (Haskell): its own name, or for a
-- parameterized ability, the instance's name first (storeInt32Load).
fieldName :: C.Ability -> String -> String
fieldName a op
  | null (C.abilityArguments a) = op
  | otherwise = lowerFirst (interfaceName a) ++ capitalize op
  where lowerFirst (c : cs) = toEnum (fromEnum c + (if c >= 'A' && c <= 'Z' then 32 else 0)) : cs
        lowerFirst [] = []

-- An ability as the spec writes it: Store Int32.
displayName :: C.Ability -> String
displayName a = unwords (C.abilityName a : map typeWord (C.abilityArguments a))

-- A type as part of a name: Int32, ListText, Receipt.
typeWord :: C.Type -> String
typeWord t = case t of
  C.Constructor n args -> capitalize (filter (`notElem` ("._" :: String)) (short n)) ++ concat [typeWord a | C.TypeArgument a <- args]
  C.TypeVariable v -> capitalize (short (C.idText v))
  C.Arrow a b -> typeWord a ++ "To" ++ typeWord b
  where short n = reverse (takeWhile (/= ':') (reverse n))

productionName :: C.Ability -> String
productionName a = interfaceName a ++ "Handler"

specName :: C.Handler -> String
specName = capitalize . C.handlerName

recordingName :: C.Ability -> String
recordingName a = interfaceName a ++ "Recording"

-- Whether a unit has anything for the ability emitters: abilities it owns,
-- or spec handlers.
unitAbilityPieces :: C.Unit -> Bool
unitAbilityPieces u = not (null (ownAbilities u) && null (C.unitHandlers u))

-- Each unit with the abilities it owns, at every type any unit uses them,
-- then the ones it imports. Emitters generate the pieces of the first
-- (ownAbilities), and find those of the others with their owner (ownerName).
ownedAbilityUnits :: [C.Unit] -> [C.Unit]
ownedAbilityUnits units =
  [ u { C.unitAbilities = C.ownedAbilities units u ++ [a | a <- C.unitAbilities u, C.abilityOwner a /= C.unitId u] }
  | u <- units ]

-- The abilities whose pieces a unit's code holds.
ownAbilities :: C.Unit -> [C.Ability]
ownAbilities u = [a | a <- C.unitAbilities u, C.abilityOwner a == C.unitId u]

-- The name of the unit that owns an ability.
ownerName :: C.Ability -> String
ownerName = C.idText . C.abilityOwner

-- A unit's ability at an instance.
unitAbility :: C.Unit -> C.AbilityRef -> Maybe C.Ability
unitAbility u ref = case [a | a <- C.unitAbilities u, C.abilityInstance a == ref] of
  a : _ -> Just a
  [] -> Nothing

-- The unit that owns an ability's pieces, among some units.
abilityHome :: [C.Unit] -> C.AbilityRef -> Maybe (C.Unit, C.Ability)
abilityHome = C.findAbility

-- Every ability key a property installs a handler for.
handlerKeys :: C.Property -> [String]
handlerKeys p = [C.abilityKey a | (a, _) <- C.propertyHandlers p]

-- The ability a key names, among some units'.
abilityOf :: [C.Unit] -> C.AbilityRef -> Maybe C.Ability
abilityOf units ref = snd <$> C.findAbility units ref

specHandlerOf :: [C.Unit] -> C.Id -> Maybe C.Handler
specHandlerOf units identity = case [h | u <- units, h <- C.unitHandlers u, C.handlerId h == identity] of
  h : _ -> Just h
  [] -> Nothing

-- An operation's parameter and result types.
operationTypes :: C.Ability -> String -> ([C.Type], C.Type)
operationTypes ability op = maybe ([], C.scalarType "Unit") C.functionType (lookup op (C.abilityOperations ability))
