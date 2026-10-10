-- | Evidence passing for .NET: how laws and definitions perform operations,
-- raise and catch typed failures, scope handlers and count recorded calls,
-- and the names of each ability's generated pieces. Handlers travel in the
-- schema, as the runtime's Effects module keeps them.
-- ref:DEC-typed-core-boundary ref:DEC-csharp-over-fsharp
module LawSpec.DotNet.Effects
  ( abilities, handlers, uses, external, factory, factoryWith, factories, withHandlers
  , interfaceType, interfaceTypeOf, abilityNamespace, bridgeName, bridgeCall, productionFunction, specFunction
  , hasDefault, defaultUnits, operationMember
  ) where

import qualified LawSpec.Core as C
import qualified LawSpec.AbilityNames as N
import LawSpec.DotNet.Code
import LawSpec.DotNet.Names
import LawSpec.DotNet.Entries
import qualified LawSpec.DotNet.Expr as X
import Data.List (nubBy)

-- | The program's abilities, each instance once, without Fail.
abilities :: [C.Unit] -> [C.Ability]
abilities units = nubBy (\a b -> C.abilityInstance a == C.abilityInstance b)
  [a | u <- units, a <- N.ownAbilities u, not (C.isFail (C.abilityInstance a))]

handlers :: [C.Unit] -> [C.Handler]
handlers = nubBy (\a b -> C.handlerId a == C.handlerId b) . concatMap C.unitHandlers

-- | The abilities a declaration's adapter is handed, in order.
uses :: C.Declaration -> [C.AbilityRef]
uses = filter (not . C.isFail) . C.declarationUses

-- | The built-in abilities whose default handlers the runtime provides.
defaultUnits :: [String]
defaultUnits = ["lawspec.time", "lawspec.randomness", "lawspec.host", "lawspec.logging", "lawspec.concurrent", "lawspec.crypto"]

hasDefault :: C.Ability -> Bool
hasDefault = (`elem` defaultUnits) . C.idText . C.abilityOwner

-- | The namespace of an owner unit's ability interfaces.
abilityNamespace :: C.Id -> String
abilityNamespace owner = "LawSpec.Abilities." ++ concatMap pascal (splitDots (C.idText owner))

-- | An ability's native interface: IGateway, IStoreInt32.
interfaceType :: C.Ability -> String
interfaceType a = abilityNamespace (C.abilityOwner a) ++ ".I" ++ pascal (N.interfaceName a)

interfaceTypeOf :: [C.Unit] -> C.AbilityRef -> Either String String
interfaceTypeOf units ref = maybe (Left ("unknown .NET ability " ++ C.abilityKey ref)) (Right . interfaceType) (N.abilityOf units ref)

-- | An operation's member on the interface.
operationMember :: String -> String
operationMember = pascal

-- | The bridge functions of an ability: <ability>ToNative and so on, in the
-- generated abilities module.
bridgeName :: C.Ability -> String -> String
bridgeName a suffix = camel (concatMap pascal (splitDots (C.idText (C.abilityOwner a))) ++ pascal (N.interfaceName a)) ++ suffix

bridgeCall :: C.Ability -> String -> [Expr] -> Expr
bridgeCall a suffix = Call (Fn ("LawSpec.Generated.Abilities." ++ bridgeName a suffix) ("LawSpec.Generated.Abilities." ++ pascal (bridgeName a suffix)))

-- | The function making an ability's production handler, in its owner's
-- generated module.
productionFunction :: C.Ability -> (String, String)
productionFunction a = (generatedModule (C.abilityOwner a), camel (N.interfaceName a) ++ "Production")

-- | The function making a spec handler, in its unit's generated module.
specFunction :: [C.Unit] -> C.Handler -> (String, String)
specFunction units h = (generatedModule owner, camel (C.handlerName h) ++ "Handler")
  where owner = head ([C.unitId u | u <- units, any ((== C.handlerId h) . C.handlerId) (C.unitHandlers u)] ++ [C.Id ""])

qualified :: (String, String) -> [Expr] -> Expr
qualified (m, f) = Call (Fn (m ++ "." ++ f) (m ++ "." ++ pascal f))

-- | The handler a law or a handle expression installs for an ability.
factory :: [C.Unit] -> Expr -> Expr -> C.AbilityRef -> C.HandlerRef -> Either String Expr
factory units schema symbols = factoryWith units schema symbols Nothing

-- | A handler's factory; a production handler of an ability made with a
-- resource is given the case's resource.
factoryWith :: [C.Unit] -> Expr -> Expr -> Maybe Expr -> C.AbilityRef -> C.HandlerRef -> Either String Expr
factoryWith units schema symbols resource ability choice = case choice of
  C.ProductionHandler -> do
    a <- maybe (Left ("unknown .NET ability " ++ C.abilityKey ability)) Right (N.abilityOf units ability)
    if hasDefault a && C.abilityNative a == Nothing
      then pure (call "Defaults" "handler" [Str (C.abilityKey (C.abilityInstance a))])
      else case (C.abilityResource a, resource) of
        (Just _, Just r) -> pure (qualified (productionFunction a) [schema, symbols, r])
        (Just _, Nothing) -> pure (call "Effects" "resourceRequired" [Str (C.abilityKey (C.abilityInstance a))])
        _ -> pure (qualified (productionFunction a) [schema, symbols])
  C.SpecHandler identity -> do
    h <- maybe (Left ("unknown .NET handler " ++ C.idText identity)) Right (N.specHandlerOf units identity)
    let made = qualified (specFunction units h) [schema, symbols]
    pure (if not (null (C.handlerAlso h))
      then call "Effects" "shared" [schema, Str (C.idText identity), Lambda [] (Ty "Effects.Handler" "Effects.Handler") made]
      else made)
  C.RecordingHandler inner -> do
    made <- factoryWith units schema symbols resource ability inner
    pure (call "Effects" "recording" [made])

-- | The factories of a law's or handle expression's handler choices.
factories :: [C.Unit] -> Expr -> [(C.AbilityRef, C.HandlerRef)] -> Either String Expr
factories units symbols choices = do
  made <- mapM (\(a, h) -> do
    f <- factory units (Var "factorySchema") symbols a h
    pure (TupleOf [Str (C.abilityKey a), Lambda [("factorySchema", tSchema)] (Ty "Effects.Handler" "Effects.Handler") f]))
    [(a, h) | (a, h) <- choices, not (C.isFail a)]
  pure (ListOf (Ty "string * (Schema.Schema -> Effects.Handler)" "Tuple<string, FSharpFunc<Schema.Schema, Effects.Handler>>") made)

-- | A body run with a law's handlers in scope.
withHandlers :: [C.Unit] -> Expr -> Expr -> [(C.AbilityRef, C.HandlerRef)] -> (Expr -> Expr) -> Either String Expr
withHandlers units schema symbols choices body
  | all (C.isFail . fst) choices = pure (body schema)
  | otherwise = do
      made <- factories units symbols choices
      pure (call "Effects" "withScope" [schema, made, Lambda [("scoped", tSchema)] tValue (body (Var "scoped"))])

-- | Calls from a law or definition: to entries, to operations, and the
-- handler and failure forms.
external :: [C.Unit] -> X.Context -> C.Expr -> [Expr] -> Either String Expr
external units context expression args = case C.expressionNode expression of
  C.ExternalCall identity _ -> case lookup identity (entries units) of
    Just e -> pure (entryCall e (schema : symbols : args))
    Nothing -> Left ("unresolved .NET call: " ++ C.idText identity)
  C.Perform operation _ | C.isFail (C.operationAbility operation), [v] <- args ->
    pure (call "Effects" "raiseFailure" [Str (C.abilityKey (C.operationAbility operation)), v])
  C.Perform operation _ -> do
    ref <- X.contextType context (C.expressionType expression)
    pure (call "Schema" "validate" [call "Effects" "perform" [schema, Str (C.abilityKey (C.operationAbility operation)),
      Str (C.operationName operation), ListOf tValue args], ref, schema])
  C.Handle (C.WithHandler ability choice) _ | [body] <- args -> do
    made <- factories units symbols [(ability, choice)]
    pure (call "Effects" "withScope" [schema, made, body])
  C.Handle (C.CatchFailure ability) _ | [body] <- args -> do
    ref <- X.contextType context (C.expressionType expression)
    let side tag = Lambda [("failureValue", tValue)] tValue
          (call "Schema" "construct" [Str tag, ListOf tValue [Var "failureValue"], ref, schema])
    pure (call "Effects" "attempt" [Str (C.abilityKey ability), body, side "Either::Right", side "Either::Left"])
  C.Calls operation arguments -> pure (call "Effects" "countCalls" [schema, Str (C.abilityKey (C.operationAbility operation)),
    Str (C.operationName operation), case arguments of
      Nothing -> Raw "None" "FSharpOption<FSharpList<Value>>.None"
      Just _ -> call "Runtime" "some" [ListOf tValue args]])
  _ -> Left "invalid .NET external expression"
  where
    schema = X.contextSchema context
    symbols = X.contextSymbols context
