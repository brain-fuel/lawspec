-- Names every target gives an ability's native pieces (see
-- docs/reference/language/handlers.md):
--
--   * the interface, named like the ability: Gateway;
--   * the production handler, written by hand (or bound in lawspec.edn):
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
  , nestedClashes
  , goPackageMembers, goPackageAbilities
  ) where

import Data.Char (toUpper)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import qualified LawSpec.Core as C
import LawSpec.Core.Stages (stageFailures)

-- Go packages materialize reachable checked bodies and their spec handlers.
-- Keep this closure shared by interface, body and native-bridge emission.
goPackageMembers :: [C.Unit] -> C.Unit -> ([C.Definition], [C.Handler])
goPackageMembers units unit = visit S.empty S.empty roots handlerRoots
  where
    definitions = M.fromList [(C.declarationId (C.definitionDeclaration d),d) | u <- units,d <- C.unitDefinitions u]
    handlers = M.fromList [(C.handlerId h,h) | u <- units,h <- C.unitHandlers u]
    contracts = M.fromList [(C.contractDeclaration c,c) | u <- units,c <- C.unitContracts u]
    contractTerms c = C.contractExpressions c ++ C.contractRuntimePostconditions c
    harnessTerms h = map C.coverWhen (C.harnessCover h) ++ map fst (C.harnessClassify h) ++
      C.harnessLabels h ++ maybe [] pure (C.harnessTarget h)
    expressions = concatMap C.propertyExpressions (C.unitProperties unit) ++
      concatMap (harnessTerms . C.propertyHarness) (C.unitProperties unit) ++
      maybe [] (map snd . C.harnessBenchmarks) (C.unitHarnessSettings unit) ++
      concatMap (\c -> C.contractExpressions c ++ C.contractRuntimePostconditions c) (C.unitContracts unit)
    roots = map (C.declarationId . C.definitionDeclaration) (C.unitDefinitions unit) ++ concatMap calls expressions
    handlerRoots = map C.handlerId (C.unitHandlers unit) ++ concatMap installed expressions ++
      concat [chosen choice | p <- C.unitProperties unit,(_,choice) <- C.propertyHandlers p]
    chosen (C.SpecHandler identity) = [identity]
    chosen (C.RecordingHandler inner) = chosen inner
    chosen _ = []
    calls e = case C.expressionNode e of
      C.ExternalCall identity args -> identity : concatMap calls args
      _ -> concatMap calls (C.children e)
    installed e = case C.expressionNode e of
      C.Handle (C.WithHandler _ choice) body -> chosen choice ++ installed body
      _ -> concatMap installed (C.children e)
    visit seen held [] [] =
      ([d | (identity,d) <- M.toList definitions,identity `S.member` seen],
       [h | (identity,h) <- M.toList handlers,identity `S.member` held])
    visit seen held (identity:rest) pending
      | identity `S.member` seen = visit seen held rest pending
      | otherwise = case M.lookup identity definitions of
          Nothing -> visit (S.insert identity seen) held rest pending
          Just d -> let terms = C.definitionBody d : map snd (stageFailures d) ++
                          maybe [] contractTerms (M.lookup identity contracts)
                    in visit (S.insert identity seen) held
                      (concatMap calls terms ++ maybe [] (foldr (:) []) (C.definitionPolicy d) ++ rest)
                      (concatMap installed terms ++ pending)
    visit seen held [] (identity:rest)
      | identity `S.member` held = visit seen held [] rest
      | otherwise = case M.lookup identity handlers of
          Nothing -> visit seen (S.insert identity held) [] rest
          Just h -> visit seen (S.insert identity held)
            (map snd (C.handlerClauses h) ++ maybe [] (calls . snd) (C.handlerState h)) rest

goPackageAbilities :: [C.Unit] -> C.Unit -> [C.Ability]
goPackageAbilities units unit = M.elems (M.fromList
  [(C.abilityInstance a,a) | a <- required ++ C.unitAbilities unit])
  where
    (definitions,handlers) = goPackageMembers units unit
    refs = concatMap (C.declarationUses . C.definitionDeclaration) definitions ++
      concatMap C.declarationUses (C.unitDeclarations unit) ++ concatMap C.handlerAbilities handlers ++
      [C.operationAbility op | d <- definitions,op <- C.performed (C.definitionBody d)]
    required = [a | u <- units,a <- C.unitAbilities u,C.abilityInstance a `elem` refs]

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

-- A handler named like an ability it answers (counter for Counter) would
-- share the ability's type name, so it is CounterSpec (CounterHandler is the native one).
specName :: C.Handler -> String
specName h
  | named `elem` answered = named ++ "Spec"
  | otherwise = named
  where
    named = capitalize (C.handlerName h)
    answered = [lastSegment (C.idText (C.abilityRefId ref)) | ref <- C.handlerAbilities h]
    lastSegment text = case breakColons text of
      [] -> text
      parts -> last parts
    breakColons text = case break (== ':') text of
      (before, ':' : ':' : rest) -> before : breakColons rest
      (before, _) -> [before]

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

-- Java and Kotlin nest a unit's ability pieces (interfaces, spec handlers,
-- recordings) in one class named after the unit. A nested type may not be
-- named like the class that holds it, nor like another piece, so such a
-- unit is a compile error with a clear message rather than a javac error.
nestedClashes :: String -> String -> C.Unit -> Either String ()
nestedClashes language holder u = case clashes of
  [] -> Right ()
  (piece, what) : _ -> Left (C.idText (C.unitId u) ++ ": " ++ what ++ " would be the " ++ language ++ " type " ++ piece ++
    ", but " ++ (if piece == holder then "that is the name of the class holding the unit's abilities (" ++ holder ++ ")"
      else "another piece of the unit's abilities has that name") ++
    "; rename it so its " ++ language ++ " name differs")
  where
    pieces = [(interfaceName a, "the ability " ++ displayName a) | a <- ownAbilities u] ++
      [(recordingName a, "the recording of " ++ displayName a) | a <- ownAbilities u] ++
      [(specName h, "the handler " ++ C.handlerName h) | h <- C.unitHandlers u]
    clashes = [(n, what) | (i, (n, what)) <- zip [0 :: Int ..] pieces
              , n == holder || n `elem` [m | (j, (m, _)) <- zip [0 ..] pieces, j < i]]
