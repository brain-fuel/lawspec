-- | Evidence passing for BEAM operations. A lexical scope changes the handler
-- table in its schema, never the identity of the symbols in that case.
-- ref:DEC-typed-core-boundary
module LawSpec.BeamEffects
  ( entries, abilities, handlers, abilityEntry, handlerEntry, uses
  , external, construct, factories, toNative, fromNative, interfaceParts
  ) where

import qualified LawSpec.Core as C
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.BeamCode as E
import qualified LawSpec.AbilityNames as N
import Data.List (nubBy)

entries :: [C.Unit] -> [(C.Id,String)]
entries units = [(C.declarationId d,"evaluate_" ++ show i)
  | (i,d) <- zip [0::Int ..] (concatMap C.unitDeclarations units)]

abilities :: [C.Unit] -> [C.Ability]
abilities units = nubBy (\a b -> C.abilityInstance a == C.abilityInstance b)
  [a | u <- units, a <- N.ownAbilities u, not (C.isFail (C.abilityInstance a))]

handlers :: [C.Unit] -> [C.Handler]
handlers = nubBy (\a b -> C.handlerId a == C.handlerId b) . concatMap C.unitHandlers

abilityEntry :: [C.Unit] -> C.AbilityRef -> Either String String
abilityEntry units ref = maybe (Left ("missing BEAM ability: " ++ C.abilityKey ref)) Right
  (lookup ref [(C.abilityInstance a,"ability_" ++ show i) | (i,a) <- zip [0::Int ..] (abilities units)])

handlerEntry :: [C.Unit] -> C.Id -> Either String String
handlerEntry units identity = maybe (Left ("missing BEAM handler: " ++ C.idText identity)) Right
  (lookup identity [(C.handlerId h,"handler_" ++ show i) | (i,h) <- zip [0::Int ..] (handlers units)])

uses :: C.Declaration -> [C.AbilityRef]
uses = filter (not . C.isFail) . C.declarationUses

construct :: [C.Unit] -> D.Doc -> D.Doc -> C.AbilityRef -> C.HandlerRef -> Either String D.Doc
construct units schema symbols ability choice = case choice of
  C.ProductionHandler -> do
    name <- abilityEntry units ability
    pure (E.remote "lawspec_abilities" (name ++ "_production") [schema,symbols])
  C.SpecHandler identity -> do
    name <- handlerEntry units identity
    pure (E.remote "lawspec_abilities" name [schema,symbols])
  C.RecordingHandler inner -> do
    body <- construct units schema symbols ability inner
    pure (E.remote "lawspec_beam_effects" "recording" [schema,body])

factories :: [C.Unit] -> D.Doc -> [(C.AbilityRef,C.HandlerRef)] -> Either String D.Doc
factories units symbols choices = E.record <$> mapM factory [(a,h) | (a,h) <- choices, not (C.isFail a)]
  where
    factory (ability,choice) = do
      body <- construct units (D.text "_LsFactorySchema") symbols ability choice
      pure (E.binary (C.abilityKey ability),E.lambda [D.text "_LsFactorySchema"] body)

toNative, fromNative :: [C.Unit] -> C.AbilityRef -> D.Doc -> D.Doc -> D.Doc -> Either String D.Doc
toNative = nativeBridge "_to_native"
fromNative = nativeBridge "_from_native"

nativeBridge :: String -> [C.Unit] -> C.AbilityRef -> D.Doc -> D.Doc -> D.Doc -> Either String D.Doc
nativeBridge suffix units ability schema symbols handler = do
  name <- abilityEntry units ability
  pure (E.remote "lawspec_abilities" (name ++ suffix) [schema,symbols,handler])

interfaceParts :: [C.Unit] -> C.AbilityRef -> D.Doc -> Either String D.Doc
interfaceParts units ability value = do
  name <- abilityEntry units ability
  pure (E.remote "lawspec_abilities" (name ++ "_parts") [value])

external :: [C.Unit] -> D.Doc -> D.Doc -> C.Expr -> [D.Doc] -> Either String D.Doc
external units symbols schema expression args = case C.expressionNode expression of
  C.ExternalCall identity _ -> maybe (Left ("unresolved BEAM call: " ++ C.idText identity))
    (\name -> pure (E.remote "lawspec_definitions" name (schema : symbols : args))) (lookup identity (entries units))
  C.Perform operation _ | C.isFail (C.operationAbility operation), [value] <- args ->
    pure (E.remote "lawspec_beam_effects" "raise_failure"
      [E.binary (C.abilityKey (C.operationAbility operation)),value])
  C.Perform operation _ -> do
    ref <- E.typeReference (C.expressionType expression)
    pure (E.remote "lawspec_beam_schema" "validate"
      [E.remote "lawspec_beam_effects" "perform" [schema,E.binary (C.abilityKey (C.operationAbility operation)),
        E.binary (C.operationName operation),E.array args],ref,schema])
  C.Handle (C.WithHandler ability choice) _ | [body] <- args -> do
    choices <- factories units symbols [(ability,choice)]
    pure (E.remote "lawspec_beam_effects" "with_scope" [schema,choices,body])
  C.Handle (C.CatchFailure ability) _ | [body] <- args -> do
    ref <- E.typeReference (C.expressionType expression)
    let side tag = E.lambda [D.text "_LsFailureValue"] (E.remote "lawspec_beam_schema" "construct"
          [E.binary tag,E.array [D.text "_LsFailureValue"],ref,schema])
    pure (E.remote "lawspec_beam_effects" "attempt" [E.binary (C.abilityKey ability),body,
      side "Either::Right",side "Either::Left"])
  C.Calls operation arguments -> pure (E.remote "lawspec_beam_effects" "count_calls"
    [schema,E.binary (C.abilityKey (C.operationAbility operation)),E.binary (C.operationName operation),
      case arguments of Nothing -> E.atom "any"; Just _ -> E.array args])
  _ -> Left "invalid BEAM external expression"
