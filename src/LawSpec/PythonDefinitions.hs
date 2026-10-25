-- | Framework-independent total definitions with checked native Python APIs.
module LawSpec.PythonDefinitions (emitPythonDefinitions, emitPythonDefinitionsWithNativeBridge, definitionCalls) where

import Control.Monad (forM)
import LawSpec.Core.Policy
import LawSpec.Core
import LawSpec.Core.DefinitionContracts (checkedDefinitionContracts)
import LawSpec.Core.Evidence (runtimePostconditions)
import LawSpec.Common (Artifact(..), pythonUnitFile)
import qualified LawSpec.PythonData as Native
import LawSpec.PythonTypes (namesFor)
import qualified LawSpec.PythonExpr as E
import qualified LawSpec.Code.Doc as D
import Data.List (nub, nubBy, sortOn, intercalate)
import LawSpec.AbilityNames (specName, interfaceName)
import LawSpec.RuntimeSources (runtimeSource)
import LawSpec.Typed.Python (PythonTyped(..), emitPythonTyped)
import LawSpec.Typed.Plan (TypedPlan(..))
import LawSpec.Naming (escapeKeyword, claimAll, scopeWith, nativeIdentifier, localIdentifier, NameKind(..), readableDefinitionName, sourceDefinitionName)
import LawSpec.SourceLink (labelled, sourceLink)
import qualified Data.Map.Strict as M

-- | Generated tests call checked definitions by these names, so every test
-- file agrees.
-- A definition's function is named after it (LawSpec.Naming), with _2 only
-- when two definitions would share a name.
definitionCalls :: [DataDeclaration] -> [Unit] -> [(Id,String)]
definitionCalls declarations units = [(identity, "_definitions." ++ name) | (identity, name) <- definitionNames declarations units]

definitionNames :: [DataDeclaration] -> [Unit] -> [(Id,String)]
definitionNames declarations units = zip (map (declarationId . definitionDeclaration) definitions)
  (fst (claimAll (scopeWith (E.pythonReserved ++ moduleNames)) (map base definitions)))
  where
    definitions = concatMap unitDefinitions units
    -- Data types are named as the generated code names them.
    shown = either (const []) id (namesFor declarations)
    display ty = case ty of
      Constructor n args | Just name <- lookup (Id n) shown -> Constructor name (map display' args)
      Constructor n args -> Constructor n (map display' args)
      _ -> ty
    display' (TypeArgument t) = TypeArgument (display t)
    display' a = a
    base d = let declaration = definitionDeclaration d
      in nativeIdentifier "python" FunctionName
           (readableDefinitionName (declarationName declaration) (map display (fst (functionType (declarationType declaration)))))
    moduleNames = ["data", "ls", "symbols", "result", "checked_result"]

-- | Checked definitions are emitted as ordinary Python code, so adapters and tests call
-- the same proved implementation. ref:DEC-total-definitions
emitPythonDefinitions :: D.Layout -> Int -> [DataDeclaration] -> [Unit] -> Either String [Artifact]
emitPythonDefinitions = emitPythonDefinitionsWithNativeBridge False

-- | Binding registration is part of the module header, before any body calls.
emitPythonDefinitionsWithNativeBridge :: Bool -> D.Layout -> Int -> [DataDeclaration] -> [Unit] -> Either String [Artifact]
emitPythonDefinitionsWithNativeBridge _ _ _ _ units | null (concatMap unitDefinitions units) = pure []
emitPythonDefinitionsWithNativeBridge nativeBridge layout bits declarations units = do
  contracts <- checkedDefinitionContracts bits declarations units
  typed <- emitPythonTyped bits declarations units
  bodies <- mapM (\(index, d) -> maybe (implementation contracts (index, d)) (bridge typed index d)
      (pyTypedFunction typed (declarationId (definitionDeclaration d))))
    (zip [0::Int ..] (concatMap unitDefinitions units))
  wrappers <- mapM nativeUnit (filter (not . null . unitDefinitions) units)
  let hasTyped = not (M.null (typedDefinitions (pyTypedPlan typed)))
      typedFiles = if hasTyped
        then [ Artifact "src/lawspec_typed.py" (pyTypedModule typed) "generated" "source"
             , Artifact "src/lawspec_fast.py" (runtimeSource "python-fast") "generated" "source" ]
        else []
  pure (file True "src/lawspec_definition_bodies.py" ([("importlib", "_importlib")] ++ [("lawspec_typed", "_typed") | hasTyped]) (adapterLoader : bodies) : wrappers ++ typedFiles)
  where
    -- A typed definition's dynamic entry converts its arguments and result.
    bridge typed _ d function = do
      let (argTypes, resultType) = functionType (declarationType (definitionDeclaration d))
          identity = declarationId (definitionDeclaration d)
          arguments = argumentNames d
          needsContext = identity `elem` typedContextual (pyTypedPlan typed)
          call = E.call ("_typed." ++ pyTypedTo typed resultType) [E.call ("_typed." ++ function)
            ([D.text "symbols" | needsContext] ++ [E.call ("_typed." ++ pyTypedFrom typed t) [D.text a] | (t, a) <- zip argTypes arguments])]
      pure (linkComment d <> E.suite (D.text ("def " ++ functionNameOf d) <> D.delimitTrailing 4 "(" ")" (map D.text ("symbols" : arguments)))
        (contextual identity (D.text "return " <> call)))
    width = D.text "MACHINE_BITS"
    names = definitionNames declarations units
    functionNameOf d = maybe "unnamed" id (lookup (declarationId (definitionDeclaration d)) names)
    -- A definition's arguments keep their source names.
    argumentNames d = fst (claimAll (scopeWith (E.pythonReserved ++ ["result", "checked_result"]))
      [localIdentifier "python" (binderName b) | b <- definitionArguments d])
    -- Each function's comment links it to its definition.
    linkComment d = let declaration = definitionDeclaration d
      in D.lineComment 88 "# " (labelled (sourceDefinitionName (declarationName declaration)) (sourceLink (declarationOrigin declaration)))
    callees = definitionCalls declarations units
    definitionIds = map (declarationId . definitionDeclaration) (concatMap unitDefinitions units)
    adapters = [(declarationId d, (idText (unitId u), d)) | u <- units, d <- unitDeclarations u,
      declarationId d `notElem` definitionIds]
    nubBinders = nubBy (\a b -> binderId a == binderId b)
    file loadsHandlers path imports bodies = Artifact path (D.render layout (
      D.text "# Generated by LawSpec. Do not edit." <> D.hardline <>
      D.text "from __future__ import annotations" <> D.hardline <> D.hardline <>
      D.text "import builtins as _builtins" <>
      D.hardline <> D.hardline <>
      D.joinWith D.hardline (concat
        [[D.text ("import " ++ moduleName ++ " as " ++ alias)] ++
          [D.text "import lawspec_native as _lawspec_bridge" | nativeBridge && loadsHandlers && moduleName == "lawspec_runtime"]
        | (moduleName,alias) <- sortOn fst (imports ++
            [("lawspec_data","data"),("lawspec_runtime","ls"),("lawspec_schema","_schema")])]) <>
      D.hardline <> D.hardline <> D.text "_lawspec_schema = data.make_schema()" <>
      (if usesBits then D.hardline <> D.text "# The machine profile's integer width." <> D.hardline <>
        D.text ("MACHINE_BITS = " ++ show bits) else mempty) <>
      D.hardline <> D.hardline <> D.hardline <>
      D.joinWith (D.hardline <> D.hardline <> D.hardline) bodies <> D.hardline)) "generated" "source"
      where usesBits = "MACHINE_BITS" `elem` words (map (\c -> if c == '_' || c `elem` ['A'..'Z'] then c else ' ')
              (D.render D.Compact (mconcat bodies)))
    contextual identity body = E.suite (D.text "try") body <> D.hardline <>
      E.suite (D.text "except " <> D.delimitTrailing 4 "(" ")"
        (map D.text ["_builtins.ValueError", "_builtins.TypeError", "_builtins.OverflowError"]) <> D.text " as error")
        (D.text "raise " <> E.call "_builtins.ValueError"
          [D.group (E.quoted (idText identity ++ ": ") <> D.softline <>
            D.text "+ _builtins.str(error)")] <> D.text " from error")
    assign name value = D.text (name ++ " = ") <> D.statementValue value
    -- Adapter modules load when first called, so an adapter that imports its
    -- unit's definitions does not make a cycle.
    adapterLoader = E.suite (D.text "def _adapters(module: _builtins.str)")
      (D.text "return _importlib.import_module(module)")
    schemaCall name ty value = do
      ref <- Native.pythonTypeReferenceDoc ty
      pure (E.call ("_lawspec_schema." ++ name) [ref,value,width,D.text "symbols"])
    -- A handler's values cross with the handler schema (ls.handler_schema).
    handlerCall name ty value = do
      ref <- Native.pythonTypeReferenceDoc ty
      pure (E.handlerSchemaCall name [ref,value,width,D.text "symbols"])
    implementation contracts (_,d) = do
      let binders = definitionArguments d ++ nestedBinders (definitionBody d)
          locals = zip (nub (map binderId binders)) (fst (claimAll (scopeWith (E.pythonReserved ++ ["result", "checked_result"]))
            [localIdentifier "python" (binderName b) | b <- nubBinders binders]))
          local identity = maybe (error "unresolved Python local") id (lookup identity locals)
          arguments = map (local . binderId) (definitionArguments d)
          external term values = case expressionNode term of
            -- raise aborts to the nearest attempt of its Fail ability.
            Perform op [_] | isFail (operationAbility op) ->
              pure (E.call "ls.raise_failure" (E.quoted (abilityKey (operationAbility op)) : values))
            -- An operation goes to the handler the law installed in symbols
            -- for its ability (evidence passing).
            Perform op args -> do
              nativeValues <- sequence [handlerCall "to_native" (expressionType a) value | (a, value) <- zip args values]
              let invocation = E.call "ls.handler" [D.text "symbols", E.quoted (abilityKey (operationAbility op))] <> D.text "." <> E.call (operationName op) nativeValues
              result <- if expressionType term == Constructor "Unit" []
                then pure (E.call "ls.unit_result" [invocation])
                else handlerCall "from_native" (expressionType term) invocation
              -- An operation that fails with E: a native handler raises
              -- ls.Fail with a native E, which becomes the failure.
              case findAbility units (operationAbility op) >>= lookup (operationName op) . abilityFailures . snd of
                Just failing@(AbilityRef _ [failure]) -> do
                  convert <- handlerCall "from_native" failure (D.text "_failure")
                  pure (E.call "ls.native_failures" [E.quoted (abilityKey failing), D.text "lambda _failure: " <> convert, D.text "lambda: " <> result])
                _ -> pure result
            -- prelude.attempt e: Right of e's value, or Left of its failure.
            Handle (CatchFailure ability) _ | [body] <- values ->
              pure (E.call "ls.attempt" [E.quoted (abilityKey ability), D.text "lambda: " <> body,
                D.text "lambda _value: ls.construct('Either::Right', [_value])",
                D.text "lambda _value: ls.construct('Either::Left', [_value])"])
            -- handle e with h end: e runs with h installed for its ability,
            -- made afresh each time.
            Handle (WithHandler ability (SpecHandler h)) _ | [body] <- values ->
              pure (E.call "ls.with_handlers" [D.text "symbols",
                D.delimitTrailing 4 "{" "}" [E.quoted (abilityKey ability) <> D.text ": " <> specConstruction h],
                D.text "lambda: " <> body])
            ExternalCall declaration _ | Just name <- lookup declaration callees ->
              pure (E.call (drop (length ("_definitions." :: String)) name) (D.text "symbols":values))
            -- An orchestration calls an adapter natively: the values cross
            -- to native and back through the schema, as in the tests.
            ExternalCall declaration _ | Just (owner, adapter) <- lookup declaration adapters -> do
              let (parameterTypes, resultType) = functionType (declarationType adapter)
              nativeValues <- sequence [schemaCall "to_native" ty value | (ty, value) <- zip parameterTypes values]
              -- An adapter that uses abilities gets their handlers first.
              let handlers = [E.call "ls.handler" [D.text "symbols", E.quoted (abilityKey a)] | a <- declarationUses adapter, not (isFail a)]
                  invocation = E.call "_adapters" [E.quoted owner] <> D.text "." <> E.call (declarationName adapter) (handlers ++ nativeValues)
              -- A Unit adapter returns None, which is the Unit value.
              let fromNative value
                    | resultType == Constructor "Unit" [] = pure (E.call "ls.unit_result" [value])
                    | otherwise = schemaCall "from_native" resultType value
              if declarationAsync adapter
                then do
                  -- Within its stage's timeout and hedge, when it has them.
                  convert <- fromNative (D.text "_native")
                  pure (E.call "ls.await_step" [D.text "symbols", D.text "lambda: " <> invocation, D.text "lambda _native: " <> convert])
                else do
                  result <- fromNative invocation
                  -- An adapter that fails with E: native code raises ls.Fail.
                  case [a | a@(AbilityRef _ [_]) <- declarationUses adapter, isFail a] of
                    ability@(AbilityRef _ [failure]) : _ -> do
                      convert <- schemaCall "from_native" failure (D.text "_failure")
                      pure (E.call "ls.native_failures" [E.quoted (abilityKey ability), D.text "lambda _failure: " <> convert,
                        D.text "lambda: " <> result, D.text "()"])
                    _ -> pure result
            _ -> Left "unresolved Python total call"
      rendered <- E.renderExpression declarations bits local external (definitionBody d)
      -- A workflow stage with policies runs under the workflow runtime.
      body <- case definitionPolicy d of
        Nothing -> pure rendered
        Just policy | policyFrame policy -> pure (E.call "ls.run_workflow" [D.text "symbols", D.text "lambda: " <> rendered])
        Just policy -> do
          config <- policyDoc (idText (declarationId (definitionDeclaration d))) policy
          let key = case arguments of
                argument : _ -> D.text argument
                [] -> D.text "None"
          pure (E.call "ls.run_stage" [D.text "symbols", config, D.text "lambda: " <> rendered, key])
      -- Arguments and results were checked where they were built, decoded
      -- or drawn; the native wrappers check values crossing from adapters.
      let checks = []
          result = D.text "result"
      let contract = lookup (declarationId (definitionDeclaration d)) [(contractDeclaration c,c) | c <- contracts]
      statements <- case contract of
        Nothing -> pure (checks ++ [assign "result" body,D.text "return " <> result])
        Just c -> do
          let aliases = zip (map binderId (contractArguments c))
                (map (local . binderId) (definitionArguments d)) ++
                [(binderId (contractResult c),"checked_result")] ++
                zip (map binderId contractBinders) (fst (claimAll (scopeWith (E.pythonReserved ++ ["result", "checked_result"] ++ arguments))
                  [localIdentifier "python" (binderName b) | b <- contractBinders]))
              contractBinders = concatMap nestedBinders (contractPreconditions c ++ contractPostconditions c ++ contractRuntimePostconditions c)
              resolve identity = maybe (error "unbound definition contract binder") id (lookup identity aliases)
              require stage predicate = do
                expression <- E.renderExpression declarations bits resolve external predicate
                pure (E.call "ls.require_contract" [expression,E.quoted stage])
          pre <- mapM (require "precondition") (contractPreconditions c)
          -- Proved by the totality audit; see LawSpec.Core.Evidence.
          post <- mapM (require "postcondition") (runtimePostconditions c)
          pure (checks ++ pre ++ [assign "result" body,assign "checked_result" result] ++
            post ++ [D.text "return checked_result"])
      pure (linkComment d <> E.suite (D.text ("def " ++ functionNameOf d) <>
        D.delimitTrailing 4 "(" ")" (map D.text ("symbols":arguments)))
        (contextual (declarationId (definitionDeclaration d)) (D.joinWith D.hardline
          statements)))
    evaluator identity = maybe (Left "unresolved Python policy definition") (Right . drop (length ("_definitions." :: String)))
      (lookup identity callees)
    policyDoc key policy = do
      gates <- policyGates policy
      retry <- case policyRetry policy of
        Nothing -> pure (D.text "None")
        Just r -> do
          strategy <- case retryStrategy r of
            Immediate -> pure (tuple [E.quoted "immediate"])
            Fixed delay -> pure (tuple [E.quoted "fixed", int delay])
            Linear delay step -> pure (tuple [E.quoted "linear", int delay, int step])
            Exponential delay factor cap -> pure (tuple [E.quoted "exponential", int delay, int factor, maybe (D.text "None") int cap])
            Fibonacci delay -> pure (tuple [E.quoted "fibonacci", int delay])
            Custom decide -> do
              name <- evaluator decide
              pure (tuple [E.quoted "custom", D.text ("lambda attempt, error, previous: ls.retry_decision(" ++ name ++
                "(symbols, attempt, error, ls.DataValue(\"lawspec.time::type::Duration::Duration\", (previous,))))")])
          condition <- case retryWhen r of
            Nothing -> pure (D.text "None")
            Just p -> (\name -> lambda ["error"] (name ++ "(symbols, error)")) <$> evaluator p
          pure (E.call "ls.Retry" [strategy, int (retryAttempts r), E.quoted (jitterName (retryJitter r)), condition])
      compensate <- case policyCompensate policy of
        Nothing -> pure (D.text "None")
        Just undo -> (\name -> lambda ["value"] (name ++ "(symbols, value)")) <$> evaluator undo
      pure (E.call "ls.StagePolicy" [E.quoted (policyStage policy), retry, maybe (D.text "None") int (policyTimeout policy),
        E.quoted key, tuple gates, maybe (D.text "None") int (policyCache policy),
        D.text (if null (policyFailures policy) then "False" else "True"), compensate,
        maybe (D.text "None") (\h -> tuple [int (hedgeDelay h), int (hedgeMost h)]) (policyHedge policy)])
    -- A gate's callbacks call the unit's copies of the resilience unit's
    -- state machines, with the policy's numbers.
    policyGates policy = do
      breaker <- forM (policyBreaker policy) $ \b -> do
        start <- evaluator (breakerStart b)
        admit <- evaluator (breakerAdmit b)
        record <- evaluator (breakerRecord b)
        pure (E.call "ls.Gate" [E.quoted "breaker", lambda ["now"] (start ++ "(symbols, now)"),
          lambda ["state", "now"] (admit ++ "(symbols, state, now)"),
          lambda ["state", "now", "succeeded"] (record ++ "(symbols, " ++ show (breakerFailures b) ++ ", " ++ show (breakerWindow b) ++ ", " ++
            show (breakerCooldown b) ++ ", state, now, succeeded)"), D.text "None"])
      limit <- forM (policyLimit policy) $ \l -> do
        start <- evaluator (limitStart l)
        admit <- evaluator (limitAdmit l)
        let numbers = show (limitCount l) ++ ", " ++ show (limitPeriod l)
        pure (E.call "ls.Gate" [E.quoted "limit", lambda ["now"] (start ++ "(symbols, " ++ numbers ++ ", now)"),
          lambda ["state", "now"] (admit ++ "(symbols, " ++ numbers ++ ", state, now)"), D.text "None", waitDoc (limitWait l)])
      bulkhead <- forM (policyBulkhead policy) $ \b -> do
        start <- evaluator (bulkheadStart b)
        admit <- evaluator (bulkheadAdmit b)
        release <- evaluator (bulkheadRelease b)
        let n = show (bulkheadLimit b)
        pure (E.call "ls.Gate" [E.quoted "bulkhead", lambda ["now"] (start ++ "(symbols, " ++ n ++ ", now)"),
          lambda ["state", "now"] (admit ++ "(symbols, " ++ n ++ ", state, now)"),
          lambda ["state", "now", "succeeded"] (release ++ "(symbols, state)"), waitDoc (bulkheadWait b)])
      pure (maybe [] pure breaker ++ maybe [] pure limit ++ maybe [] pure bulkhead)
    -- A callback calling a definition, laid out as a call.
    lambda parameters body = case break (== '(') body of
      (f, '(' : rest) | not (null rest), last rest == ')', '(' `notElem` init rest ->
        E.lambdaExpression (map D.text parameters) (E.call f (map D.text (commaParts (init rest))))
      _ -> D.text ("lambda " ++ intercalate ", " parameters ++ ": " ++ body)
    commaParts text = case break (== ',') text of
      (part, ',' : ' ' : rest) -> part : commaParts rest
      (part, _) -> [part]
    waitDoc wait = case wait of
      Nothing -> D.text "None"
      Just Nothing -> D.text "-1"
      Just (Just d) -> int d
    tuple [] = D.text "()"
    tuple [item] = D.group (D.text "(" <> D.nest 4 (D.softbreak <> item <> D.text ",") <> D.softbreak <> D.text ")")
    tuple items = D.delimitTrailing 4 "(" ")" items
    int n = D.text (show n)
    jitterName j = case j of
      NoJitter -> "none"
      FullJitter -> "full"
      EqualJitter -> "equal"
      DecorrelatedJitter -> "decorrelated"
    nativeUnit unit = do
      wrappers <- mapM native (unitDefinitions unit)
      let path = "src/lawspec_definitions/" ++ pythonUnitFile (map (idText . unitId) units) (idText (unitId unit))
      pure (file False path [("lawspec_definition_bodies", "_definitions")] wrappers)
    native d = do
      let declaration = definitionDeclaration d
          (args,result) = functionType (declarationType declaration)
          -- Parameters keep their source names; each is replaced by its
          -- checked logical value before the call.
          values = fst (claimAll (scopeWith (E.pythonReserved ++ ["result", "checked_result"] ++
              [n | (_, n, _, _) <- handlerParameters declaration]))
            [localIdentifier "python" (binderName b) | b <- definitionArguments d])
      types <- mapM (Native.pythonDataTypeDoc declarations) args
      resultType <- Native.pythonDataTypeDoc declarations result
      arguments <- sequence [schemaCall "from_native" ty (D.text value) | (ty,value) <- zip args values]
      name <- maybe (Left "unresolved Python native call") Right (lookup (declarationId declaration) callees)
      output <- schemaCall "to_native" result (D.text "result")
      let handlers = handlerParameters declaration
          parameters = D.text "symbols: _builtins.dict[_builtins.str, _builtins.object]" :
            [D.text (name ++ ": " ++ show ("lawspec_abilities." ++ idText (unitId u) ++ "." ++ interfaceName a)) | (_, name, u, a) <- handlers] ++
            [D.text (value ++ ": ") <> ty | (value,ty) <- zip values types]
          -- Native code passes a definition's handlers explicitly; they are
          -- installed in symbols, where the operations it performs find them.
          installs = [E.call "ls.install_handlers" [D.text "symbols", D.delimitTrailing 4 "{" "}"
            [E.quoted (abilityKey ability) <> D.text (": " ++ name) | (ability, name, _, _) <- handlers]] | not (null handlers)]
          inputs = installs ++ [assign value checked | (value, checked) <- zip values arguments]
          invocation = E.call name (D.text "symbols" : map D.text values)
      pure (linkComment d <> E.suite (D.text ("def " ++ declarationName declaration) <>
        D.delimitTrailing 4 "(" ")" parameters <> D.text " -> " <> resultType)
        (contextual (declarationId declaration) (D.joinWith D.hardline
          (inputs ++ [assign "result" invocation,D.text "return " <> output]))))
    -- The handlers a definition's native wrapper takes, first: one per
    -- ability in its row (Fail aborts, so it has none).
    handlerParameters declaration =
      [ (ability, escapeKeyword "python" (lowerFirst (interfaceName a)), owner, a)
      | ability <- declarationUses declaration, not (isFail ability)
      , Just (owner, a) <- [findAbility units ability] ]
    -- A spec handler, made with its unit's class.
    specConstruction h = case [(o, x) | o <- units, x <- unitHandlers o, handlerId x == h] of
      (o, x) : _ -> E.call "_adapters" [E.quoted ("lawspec_abilities." ++ idText (unitId o))] <> D.text "." <> E.call (specName x) [D.text "symbols"]
      [] -> E.call "ls.unknown_handler" [E.quoted (idText h)]
    lowerFirst (c:cs) = toEnum (fromEnum c + (if c >= 'A' && c <= 'Z' then 32 else 0)) : cs
    lowerFirst [] = []
    nestedBinders expression = case expressionNode expression of
      AllElements value binder predicate -> nestedBinders value ++ [binder] ++ nestedBinders predicate
      Let binder value body -> nestedBinders value ++ [binder] ++ nestedBinders body
      AllPayloads value predicates -> nestedBinders value ++ concat
        [binder : nestedBinders predicate | (binder,predicate) <- predicates]
      Match value cases -> nestedBinders value ++ concat
        [caseBinders branch ++ nestedBinders (caseBody branch) | branch <- cases]
      _ -> concatMap nestedBinders (children expression)
