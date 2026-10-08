-- | Checked BEAM definitions are reusable production code. Tests and native
-- entry points call the same implementations and cross the same schema bridge.
-- ref:DEC-total-definitions ref:DEC-native-bindings-typed-identity
module LawSpec.BeamDefinitions
  ( emitDefinitions, external, nativeFailures, awaitNative, declarationSpec, adapterModule, entries ) where

import qualified LawSpec.Core as C
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.BeamCode as E
import qualified LawSpec.BeamExpr as Expr
import LawSpec.BeamEffects (entries, external)
import qualified LawSpec.BeamEffects as Effects
import qualified LawSpec.BeamAbilities as Abilities
import LawSpec.Core.DefinitionContracts (checkedDefinitionContracts)
import LawSpec.Core.Evidence (runtimePostconditions)
import LawSpec.Common (Artifact(..))
import Control.Monad (forM)
import Data.Char (isUpper)
import Data.List (intercalate)

adapterModule :: C.Unit -> String
adapterModule = E.moduleName . C.unitId

-- | Native BEAM functions return their values directly. The async marker
-- makes the bridge own a monitored process, including bound native calls.
awaitNative :: C.Declaration -> D.Doc -> D.Doc
awaitNative declaration body
  | C.declarationAsync declaration = E.remote "lawspec_beam_runtime" "async_call" [E.lambda [] body]
  | otherwise = body

-- | Only an adapter's declared failure type gives a native failure meaning.
-- The same bridge validates failures from ordinary and bound native calls.
nativeFailures :: String -> [C.FailureBinding] -> D.Doc -> C.Declaration -> D.Doc -> Either String D.Doc
nativeFailures target bindings schema declaration body = case [a | a <- C.declarationUses declaration, C.isFail a] of
  [] -> pure body
  ability@(C.AbilityRef _ [failure]) : _ -> do
    ref <- E.typeReference failure
    mappings <- forM [b | b <- bindings, C.failureType b == failure] $ \binding -> do
      kind <- case (target, C.failureNative binding) of
        ("elixir", parts) | not (null parts), all (\p -> case p of c:_ -> isUpper c; [] -> False) parts ->
          pure (E.tuple [E.atom "elixir",E.atom ("Elixir." ++ intercalate "." parts)])
        ("elixir", _) -> Left "Elixir native failures require a capitalized exception module path"
        (_, [tag]) | not (null tag) -> pure (E.tuple [E.atom "tag",E.atom tag])
        _ -> Left "Erlang and Gleam native failures require one atom naming a tagged Erlang error"
      let value = E.remote "lawspec_beam_schema" "construct" [E.binary (C.idText (C.failureConstructor binding)),
            E.array [D.text "_LsExceptionMessage" | C.failureMessage binding],ref,schema]
          match = E.remote "lawspec_beam_effects" "match_exception"
            [kind,D.text "_LsExceptionClass",D.text "_LsExceptionReason"]
      pure (E.lambda [D.text "_LsExceptionClass",D.text "_LsExceptionReason"]
        (D.group (D.text "case " <> match <> D.text " of" <>
          D.nest 4 (D.softline <> D.text "no_match -> no_match;" <>
            D.softline <> D.text "{ok, _LsExceptionMessage} -> " <> E.tuple [E.atom "ok",value]) <>
          D.softline <> D.text "end")))
    pure (E.remote "lawspec_beam_effects" "native_failures" [E.binary (C.abilityKey ability),
      E.lambda [D.text "_LsNativeFailure"] (E.remote "lawspec_beam_schema" "from_native"
        [D.text "_LsNativeFailure",ref,schema]),E.lambda [] body,E.array mappings])
  _ -> Left "a BEAM failure ability requires its failure type"

declarationSpec :: Int -> [(C.Id,String)] -> [C.Unit] -> C.Declaration -> Either String D.Doc
declarationSpec bits names units declaration = do
  let (arguments,result) = C.functionType (C.declarationType declaration)
  handlers <- mapM (Abilities.nativeType "erlang" units) (Effects.uses declaration)
  parameters <- mapM (E.nativeType bits names []) arguments
  returns <- E.nativeType bits names [] result
  pure (D.group (D.text "-spec " <> E.call (E.functionName declaration) (handlers ++ parameters) <>
    D.text " ->" <> D.nest 4 (D.softline <> returns) <> D.text "."))

emitDefinitions :: String -> D.Layout -> Int -> [C.DataDeclaration] -> [C.Unit] -> [(C.Id,String)] -> Either String [Artifact]
emitDefinitions target layout bits declarations units bound = do
  verified <- checkedDefinitionContracts bits declarations units
  names <- E.dataNames declarations
  bodies <- mapM (implementation verified) [(u,d) | u <- units, d <- C.unitDeclarations u]
  wrappers <- mapM (nativeUnit names) [u | u <- units, not (null (C.unitDefinitions u))]
  let exports = [(name,2 + length (fst (C.functionType (C.declarationType d))))
        | u <- units, d <- C.unitDeclarations u, Just name <- [lookup (C.declarationId d) callees]]
  pure (file "lawspec_definitions" exports bodies : wrappers)
  where
    schema = D.text "_LsSchema"
    symbols = D.text "_LsSymbols"
    callees = entries units
    definitions = [(C.declarationId (C.definitionDeclaration d),d) | u <- units, d <- C.unitDefinitions u]
    file name exports body = Artifact ("src/" ++ name ++ ".erl")
      (D.render layout (E.moduleDoc name exports body)) "generated" "source"
    bridge method ty value = do
      ref <- E.typeReference ty
      pure (E.remote "lawspec_beam_schema" method [value,ref,schema])
    implementation verified (unit,declaration) = do
      let identity = C.declarationId declaration
          (parameterTypes,resultType) = C.functionType (C.declarationType declaration)
          arguments = ["_LsArgument" ++ show i | (i,_) <- zip [0::Int ..] parameterTypes]
          definition = lookup identity definitions
          locals = maybe [] (\d -> zip (map C.binderId (C.definitionArguments d)) arguments) definition
          resolve table variable = maybe (error ("unbound BEAM binder: " ++ C.idText variable)) id (lookup variable table)
          render table = Expr.renderExpression bits schema symbols (resolve table) (external units symbols)
      body <- case definition of
        Just d -> render locals (C.definitionBody d)
        Nothing -> case lookup identity bound of
          Just name -> pure (E.remote "lawspec_native_bindings" name (schema : symbols : map D.text arguments))
          Nothing -> do
            handlers <- mapM (\a -> Effects.toNative units a schema symbols
              (E.remote "lawspec_beam_effects" "handler" [schema,E.binary (C.abilityKey a)])) (Effects.uses declaration)
            nativeArguments <- sequence [bridge "to_native" ty (D.text arg) | (ty,arg) <- zip parameterTypes arguments]
            let nativeNames = [D.text ("_LsNativeInput" ++ show i) | (i,_) <- zip [0::Int ..] nativeArguments]
            invocation <- nativeFailures target (C.unitFailureBindings unit) schema declaration
              (awaitNative declaration (E.remote (E.nativeModule target unit) (E.nativeFunction target declaration) (handlers ++ nativeNames)))
            result <- bridge "from_native" resultType invocation
            -- A mapping describes application exceptions. Neither input nor
            -- result validation may turn into a successful expected failure.
            pure (E.apply (E.lambda nativeNames result) nativeArguments)
      let candidates = case definition of Just _ -> verified; Nothing -> C.unitContracts unit
          contracts = [c | c <- candidates, C.contractDeclaration c == identity]
      pre <- fmap concat $ forM contracts $ \c -> do
        let aliases = zip (map C.binderId (C.contractArguments c)) arguments
        mapM (require (render aliases) "precondition") (C.contractPreconditions c)
      post <- fmap concat $ forM contracts $ \c -> do
        let aliases = zip (map C.binderId (C.contractArguments c)) arguments ++
              [(C.binderId (C.contractResult c),"_LsResult")]
        mapM (require (render aliases) "postcondition")
          (case definition of Just _ -> runtimePostconditions c; Nothing -> C.contractPostconditions c ++ C.contractRuntimePostconditions c)
      name <- maybe (Left "missing BEAM declaration entry") Right (lookup identity callees)
      pure (E.function name (schema : symbols : map D.text arguments)
        [E.remote "lawspec_beam_runtime" "contextual" [E.binary (C.idText identity),E.lambda []
          (E.sequenceDoc (pre ++ [D.text "_LsResult = " <> body] ++ post ++ [D.text "_LsResult"]))]])
    require render label predicate = do
      body <- render predicate
      pure (E.remote "lawspec_beam_runtime" "require" [body,E.binary label])
    nativeUnit names unit = do
      functions <- fmap concat $ forM (C.unitDefinitions unit) $ \definition -> do
        let d = C.definitionDeclaration definition
            (parameterTypes,resultType) = C.functionType (C.declarationType d)
            arguments = [D.text ("_LsNative" ++ show i) | (i,_) <- zip [0::Int ..] parameterTypes]
            handlers = zip (Effects.uses d) [D.text ("_LsHandler" ++ show i) | i <- [0::Int ..]]
        signatures <- if target == "erlang" then pure <$> declarationSpec bits names units d else pure []
        converted <- sequence [bridge "from_native" ty arg | (ty,arg) <- zip parameterTypes arguments]
        name <- maybe (Left "missing BEAM definition entry") Right (lookup (C.declarationId d) callees)
        result <- bridge "to_native" resultType (E.remote "lawspec_definitions" name (schema : symbols : converted))
        body <- if null handlers then pure [D.text "_LsSymbols = make_ref()",
          D.text "_LsSchema = " <> E.remote "lawspec_data" "schema" [symbols],result]
          else pure <$> Abilities.publicBody units handlers result
        pure (signatures ++ [E.function (E.nativeFunction target d) (map snd handlers ++ arguments) body])
      let name = adapterModule unit ++ "_definitions" ++ (if target == "erlang" then "" else "_ffi")
          exports = [(E.nativeFunction target d,length (Effects.uses d) + length (fst (C.functionType (C.declarationType d))))
            | definition <- C.unitDefinitions unit, let d = C.definitionDeclaration definition]
      pure (file name exports functions)
