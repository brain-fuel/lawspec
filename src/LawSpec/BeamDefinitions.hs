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
import qualified LawSpec.BeamPolicy as Policy
import LawSpec.Core.DefinitionContracts (checkedDefinitionContracts)
import LawSpec.Core.Evidence (runtimePostconditions)
import LawSpec.Common (Artifact(..))
import LawSpec.Typed.Beam (BeamTyped(..), Crossing(..))
import Control.Monad (forM)
import Data.Char (isUpper)
import Data.List (intercalate)
import qualified LawSpec.BeamNames as Names
import LawSpec.Naming (typeWords)
import LawSpec.SourceLink (sourceLink, unitSourceFile)

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
            E.array (C.mapFailureFields (\ty tag fields -> E.remote "lawspec_beam_schema" "construct" [E.binary (C.idText tag), E.array fields, either error id (E.typeReference ty), schema]) (D.text "Message") binding),ref,schema]
          match = E.remote "lawspec_beam_effects" "match_exception"
            [kind,D.text "Class",D.text "Reason"]
      pure (E.lambda [D.text "Class",D.text "Reason"]
        (E.caseOf match [(E.atom "no_match",E.atom "no_match"),(E.tuple [E.atom "ok",D.text "Message"],E.tuple [E.atom "ok",value])]))
    pure (E.remote "lawspec_beam_effects" "native_failures" [E.binary (C.abilityKey ability),
      E.lambda [D.text "Failure"] (E.remote "lawspec_beam_schema" "from_native"
        [D.text "Failure",ref,schema]),E.lambda [] body,E.array mappings])
  _ -> Left "a BEAM failure ability requires its failure type"

declarationSpec :: Int -> [(C.Id,String)] -> [C.Unit] -> C.Declaration -> Either String D.Doc
declarationSpec bits names units declaration = do
  let (arguments,result) = C.functionType (C.declarationType declaration)
  handlers <- mapM (Abilities.nativeType "erlang" units) (Effects.uses declaration)
  parameters <- mapM (E.nativeType bits names []) arguments
  returns <- E.nativeType bits names [] result
  pure (D.group (D.text "-spec " <> E.call (E.functionName declaration) (handlers ++ parameters) <>
    D.text " ->" <> D.nest 4 (D.softline <> returns) <> D.text "."))

emitDefinitions :: String -> D.Layout -> Int -> Maybe BeamTyped -> [C.DataDeclaration] -> [C.Unit] -> [(C.Id,String)] -> Either String [Artifact]
emitDefinitions target layout bits typed declarations units bound = do
  verified <- checkedDefinitionContracts bits declarations units
  names <- E.dataNames declarations
  bodies <- mapM (implementation verified) [(u,d) | u <- units, d <- C.unitDeclarations u]
  wrappers <- mapM (nativeUnit names) [u | u <- units, not (null (C.unitDefinitions u))]
  let exports = [(name,2 + length (fst (C.functionType (C.declarationType d))))
        | u <- units, d <- C.unitDeclarations u, Just name <- [lookup (C.declarationId d) callees]]
  pure (file "lawspec_definitions" exports bodies : wrappers)
  where
    schema = D.text "Schema"
    symbols = D.text "Symbols"
    callees = entries units
    typedCall identity = do
      t <- typed
      f <- beamTypedFunction t identity
      pure (t,f)
    definitions = [(C.declarationId (C.definitionDeclaration d),d) | u <- units, d <- C.unitDefinitions u]
    file name exports body = Artifact ("src/" ++ name ++ ".erl")
      (D.render layout (E.moduleDoc name exports body)) "generated" "source"
    bridge method ty value = do
      ref <- E.typeReference ty
      pure (E.remote "lawspec_beam_schema" method [value,ref,schema])
    implementation verified (unit,declaration) = do
      let identity = C.declarationId declaration
          (parameterTypes,resultType) = C.functionType (C.declarationType declaration)
          definition = lookup identity definitions
          -- Arguments keep their source names; a declaration's are named
          -- for their types.
          sourceNames = case definition of
            Just d -> map C.binderName (C.definitionArguments d)
            Nothing -> [unwords (typeWords t) | t <- parameterTypes]
          arguments = Names.variables Names.generatedVariables sourceNames
          locals = maybe [] (\d -> zip (map C.binderId (C.definitionArguments d)) arguments) definition
          resolve table variable = maybe (error ("unbound BEAM binder: " ++ C.idText variable)) id (lookup variable table)
          render table = Expr.renderExpression bits schema symbols (resolve table) (external units symbols)
      body <- case definition of
        -- A typed definition runs typed: its arguments from dynamic values,
        -- and its result back. ref:DEC-typed-native-definitions
        Just _ | Just (t,f) <- typedCall identity -> do
          let context = if beamTypedContextual t identity then [schema,symbols] else []
              inputs = [beamTypedConvert t FromDynamic ty (D.text a) | (ty,a) <- zip parameterTypes arguments]
          pure [beamTypedConvert t ToDynamic resultType (E.remote "lawspec_typed" f (context ++ inputs))]
        Just d -> pure <$> (render locals (C.definitionBody d) >>= Policy.wrapDefinition units schema symbols (map D.text arguments) d)
        Nothing -> case lookup identity bound of
          Just name -> pure [E.remote "lawspec_native_bindings" name (schema : symbols : map D.text arguments)]
          Nothing -> do
            handlers <- mapM (\a -> Effects.toNative units a schema symbols
              (E.remote "lawspec_beam_effects" "handler" [schema,E.binary (C.abilityKey a)])) (Effects.uses declaration)
            nativeArguments <- sequence [bridge "to_native" ty (D.text arg) | (ty,arg) <- zip parameterTypes arguments]
            let nativeNames = Names.variables (Names.generatedVariables ++ arguments) ["Native" ++ a | a <- arguments]
            invocation <- nativeFailures target (C.unitFailureBindings unit) schema declaration
              (awaitNative declaration (E.remote (E.nativeModule target unit) (E.nativeFunction target declaration) (handlers ++ map D.text nativeNames)))
            result <- bridge "from_native" resultType invocation
            -- Arguments cross into native values before the call: a mapping
            -- describes application exceptions, so neither input nor result
            -- validation may turn into a successful expected failure.
            pure ([E.assign n a | (n,a) <- zip nativeNames nativeArguments] ++ [result])
      let candidates = case definition of Just _ -> verified; Nothing -> C.unitContracts unit
          contracts = [c | c <- candidates, C.contractDeclaration c == identity]
      pre <- fmap concat $ forM contracts $ \c -> do
        let aliases = zip (map C.binderId (C.contractArguments c)) arguments
        mapM (require (render aliases) "precondition") (C.contractPreconditions c)
      post <- fmap concat $ forM contracts $ \c -> do
        let aliases = zip (map C.binderId (C.contractArguments c)) arguments ++
              [(C.binderId (C.contractResult c),"Result")]
        mapM (require (render aliases) "postcondition")
          (case definition of Just _ -> runtimePostconditions c; Nothing -> C.contractPostconditions c ++ C.contractRuntimePostconditions c)
      name <- maybe (Left "missing BEAM declaration entry") Right (lookup identity callees)
      let statements = if null post then pre ++ body
            else pre ++ init body ++ [E.assign "Result" (last body)] ++ post ++ [D.text "Result"]
          inner = E.remote "lawspec_beam_runtime" "contextual" [E.binary (C.idText identity),E.lambda [] (E.sequenceDoc statements)]
      pure (E.linkComment (C.declarationName declaration) (sourceLink (C.declarationOrigin declaration)) <>
        E.function name (E.variable "Schema" inner : E.variable "Symbols" inner : map (\a -> E.variable a inner) arguments) [inner])
    require render label predicate = do
      body <- render predicate
      pure (E.remote "lawspec_beam_runtime" "require" [body,E.binary label])
    nativeUnit names unit = do
      functions <- forM (C.unitDefinitions unit) $ \definition -> do
        let d = C.definitionDeclaration definition
            (parameterTypes,resultType) = C.functionType (C.declarationType d)
            -- Native callers' arguments and handlers, by their source names.
            named = Names.variables Names.generatedVariables
              (map C.binderName (C.definitionArguments definition) ++ [reverse (takeWhile (/= ':') (reverse (C.idText (C.abilityRefId a)))) ++ " handler" | a <- Effects.uses d])
            arguments = map D.text (take (length parameterTypes) named)
            handlers = zip (Effects.uses d) (map D.text (drop (length parameterTypes) named))
        signatures <- if target == "erlang" then pure <$> declarationSpec bits names units d else pure []
        converted <- sequence [bridge "from_native" ty arg | (ty,arg) <- zip parameterTypes arguments]
        name <- maybe (Left "missing BEAM definition entry") Right (lookup (C.declarationId d) callees)
        result <- bridge "to_native" resultType (E.remote "lawspec_definitions" name (schema : symbols : converted))
        body <- case typedCall (C.declarationId d) of
          -- Typed: native values in and out, without the dynamic ones.
          Just (t,f) -> do
            let context = if beamTypedContextual t (C.declarationId d) then [schema,symbols] else []
                inputs = [beamTypedConvert t FromNative ty arg | (ty,arg) <- zip parameterTypes arguments]
                call = beamTypedConvert t ToNative resultType (E.remote "lawspec_typed" f (context ++ inputs))
            if null handlers then pure [call] else pure <$> Abilities.publicBody units handlers call
          Nothing -> if null handlers then pure [D.text "Symbols = make_ref()",
            D.text "Schema = " <> E.remote "lawspec_data" "schema" [symbols],result]
            else pure <$> Abilities.publicBody units handlers result
        pure (E.linkComment (C.declarationName d) (sourceLink (C.declarationOrigin d)) <> mconcat (map (<> D.hardline) signatures) <>
          E.function (E.nativeFunction target d) (map snd handlers ++ arguments) body)
      let name = adapterModule unit ++ "_definitions" ++ (if target == "erlang" then "" else "_ffi")
          exports = [(E.nativeFunction target d,length (Effects.uses d) + length (fst (C.functionType (C.declarationType d))))
            | definition <- C.unitDefinitions unit, let d = C.definitionDeclaration definition]
      pure (Artifact ("src/" ++ name ++ ".erl")
        (D.render layout (E.moduleDocFrom (unitSourceFile unit) name exports functions)) "generated" "source")
