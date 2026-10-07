-- | Native entry points and checked implementation helpers for total definitions.
module LawSpec.JavaDefinitions (emitJavaDefinitions, emitJvmDefinitionBodies, definitionCalls, orchestratedAdapters, kotlinAdapterBridge, kotlinOperationBridge, kotlinHandlerBridge, performedOperations, scopedHandlers) where

import LawSpec.Core.Stages (stageFailures)
import LawSpec.Core.Policy
import Control.Monad (forM)
import Data.Char (isAlphaNum, toUpper)
import Data.List (intercalate)
import LawSpec.Common
import LawSpec.Core
import LawSpec.Core.DefinitionContracts (checkedDefinitionContracts)
import LawSpec.Core.Evidence (runtimePostconditions)
import qualified LawSpec.JavaData as Native
import LawSpec.AbilityNames (interfaceName, specName, ownerName)
import qualified LawSpec.JavaExpr as E
import qualified LawSpec.Code.Doc as D

-- | The adapters orchestrations call, with their units.
orchestratedAdapters :: [Unit] -> [(Id, (Id, Declaration))]
orchestratedAdapters units =
  [ (callee, adapter)
  | callee <- nubIds [c | d <- concatMap unitDefinitions units, definitionOrchestrates d, c <- calls (definitionBody d)]
  , Just adapter <- [lookup callee table] ]
  where
    definitionIds = map (declarationId . definitionDeclaration) (concatMap unitDefinitions units)
    table = [(declarationId d, (unitId u, d)) | u <- units, d <- unitDeclarations u, declarationId d `notElem` definitionIds]
    calls expression = case expressionNode expression of
      ExternalCall callee arguments -> callee : concatMap calls arguments
      _ -> concatMap calls (children expression)
    nubIds = foldr (\x acc -> if x `elem` acc then acc else x : acc) []

-- | The Kotlin bridge method through which shared JVM bodies call a Kotlin
-- adapter.
kotlinAdapterBridge :: Id -> String
kotlinAdapterBridge identity = "call_" ++ map (\c -> if isAlphaNum c then c else '_') (idText identity)

-- The Kotlin bridge method through which shared JVM bodies perform a Kotlin
-- handler's operation.
kotlinOperationBridge :: Operation -> String
kotlinOperationBridge op = "perform_" ++ map (\c -> if isAlphaNum c then c else '_') (idText (operationId op))

-- The Kotlin bridge method through which shared JVM bodies make a Kotlin
-- spec handler, for handle ... with h end.
kotlinHandlerBridge :: Id -> String
kotlinHandlerBridge h = "handler_" ++ map (\c -> if isAlphaNum c then c else '_') (idText h)

-- The spec handlers checked definitions install with handle ... with h end.
scopedHandlers :: [Unit] -> [Id]
scopedHandlers units = foldr (\x acc -> if x `elem` acc then acc else x : acc) []
  [h | d <- concatMap unitDefinitions units, h <- scoped (definitionBody d)]
  where
    scoped expression = case expressionNode expression of
      Handle (WithHandler _ (SpecHandler h)) body -> h : scoped body
      _ -> concatMap scoped (children expression)

-- The operations checked definitions perform, other than raise.
performedOperations :: [Unit] -> [Operation]
performedOperations units = foldr (\x acc -> if x `elem` acc then acc else x : acc) []
  [op | d <- concatMap unitDefinitions units, op <- performs (definitionBody d), not (isFail (operationAbility op))]
  where
    performs expression = case expressionNode expression of
      Perform op arguments -> op : concatMap performs arguments
      _ -> concatMap performs (children expression)

-- | Generated tests call checked definitions by these names, so every test
-- file agrees.
definitionCalls :: [Unit] -> [(Id,String)]
definitionCalls units = [(declarationId (definitionDeclaration d),
  "lawspec.runtime.LawSpecDefinitionBodies.evaluate" ++ show i)
  | (i,d) <- zip [0::Int ..] (concatMap unitDefinitions units)]

-- | Checked definitions are emitted as ordinary Java code, so adapters and tests call
-- the same proved implementation. ref:DEC-total-definitions
emitJavaDefinitions :: D.Layout -> Int -> [DataDeclaration] -> [Unit] -> Either String [Artifact]
emitJavaDefinitions = emitDefinitions True

-- | Kotlin reuses the Java bodies of checked definitions, so the two JVM targets
-- run one implementation.
emitJvmDefinitionBodies :: D.Layout -> Int -> [DataDeclaration] -> [Unit] -> Either String [Artifact]
emitJvmDefinitionBodies = emitDefinitions False

emitDefinitions :: Bool -> D.Layout -> Int -> [DataDeclaration] -> [Unit] -> Either String [Artifact]
emitDefinitions _ _ _ _ units | null (concatMap unitDefinitions units) = pure []
emitDefinitions withNative layout bits declarations units = do
  contracts <- checkedDefinitionContracts bits declarations units
  methods <- mapM (implementation contracts) (zip [0::Int ..] (concatMap unitDefinitions units))
  let source = file "lawspec.runtime" "LawSpecDefinitionBodies"
        ["java.util.Map", "lawspec.runtime.LawSpecRuntime.Value"] methods
  native <- if withNative then mapM nativeUnit (filter (not . null . unitDefinitions) units) else pure []
  pure (source : native)
  where
    assign name value = D.group (D.text ("var " ++ name ++ " =") <>
      D.nest 4 (D.softline <> value) <> D.text ";")
    contextual identity body = D.text "try " <> D.block 2 body <>
      -- A Fail ability's failure passes through, to the attempt that awaits it.
      D.text " catch (lawspec.runtime.LawSpecRuntime.Failure failure) " <> D.block 2 (D.text "throw failure;") <>
      D.text " catch (RuntimeException error) " <>
      D.block 2 (assign "context" (E.quoted (idText identity ++ ": ")) <> D.hardline <>
        D.text "throw " <> E.call "new IllegalArgumentException"
          [D.text "context + error.getMessage()",D.text "error"] <> D.text ";")
    callees = definitionCalls units
    file package name imports methods = Artifact
      ("src/main/java/" ++ map (\c -> if c == '.' then '/' else c) package ++ "/" ++ name ++ ".java")
      (D.render layout (D.text "// Generated by LawSpec. Do not edit." <> D.hardline <>
        D.text ("package " ++ package ++ ";") <> D.hardline <> D.hardline <>
        D.joinWith D.hardline [D.text ("import " ++ item ++ ";") | item <- imports] <>
        D.hardline <> D.hardline <> D.text ("public final class " ++ name ++ " ") <>
        D.block 2 (D.joinWith (D.hardline <> D.hardline)
          ([D.text ("private " ++ name ++ "() {}"),
            D.text "private static final lawspec.runtime.LawSpecSchema _schema =" <>
              D.nest 4 (D.hardline <> D.text "lawspec.runtime.LawSpecDataSchema.create();")] ++ methods)) <> D.hardline))
      "generated" "source"
    nativeUnit unit = do
      let parts = split '.' (idText (unitId unit))
          name = concatMap capitalize (split '_' (last parts))
          package = intercalate "." ("lawspec" : "definitions" : init parts)
      methods <- mapM native (unitDefinitions unit)
      pure (file package name ["java.util.Map"] methods)
    native d = do
      let declaration = definitionDeclaration d
          (args,result) = functionType (declarationType declaration)
      nativeArgs <- mapM (Native.javaDataTypeDoc declarations) args
      nativeResult <- Native.javaDataTypeDoc declarations result
      codecs <- mapM (Native.javaCodecDocWithContext (D.text "symbols") declarations bits) args
      resultCodec <- Native.javaCodecDocWithContext (D.text "symbols") declarations bits result
      evaluator <- maybe (Left "unresolved Java definition") Right (lookup (declarationId declaration) callees)
      let handlers = [ (ability, lowerFirst (interfaceName a), abilitiesClassOfName (ownerName a) ++ "." ++ interfaceName a) | ability <- declarationUses declaration, not (isFail ability)
                     , Just (_, a) <- [findAbility units ability] ]
          parameters = D.text "Map<String, Object> symbols" : [D.text (iface ++ " " ++ name) | (_, name, iface) <- handlers] ++
            [ty <> D.text (" value" ++ show i) | (i,ty) <- zip [0::Int ..] nativeArgs]
          -- Native code passes a definition's handlers explicitly; they are
          -- installed in symbols, where the operations it performs find them.
          installs = [E.call "lawspec.runtime.LawSpecRuntime.installHandlers" [D.text "symbols",
            E.call "java.util.Map.of" (concat [[E.quoted (abilityKey ability), D.text name] | (ability, name, _) <- handlers])] <> D.text ";"
            | not (null handlers)]
          opening = "public static " ++ D.render D.Compact nativeResult ++ " " ++ declarationName declaration ++ "("
          normalSignature = D.group (D.text "public static " <> nativeResult <>
            D.text (" " ++ declarationName declaration ++ "(") <>
            D.nest 4 (D.softbreak <> D.group (D.commaSep parameters)) <> D.text ") ")
          wrappedSignature = D.text "public static " <> nativeResult <>
            D.nest 4 (D.hardline <> D.text (declarationName declaration ++ "(") <>
              D.nest 4 (D.softbreak <> D.group (D.commaSep parameters)) <> D.text ") ")
          signature = D.prefixChoice opening normalSignature wrappedSignature
          input i codec = [assign ("codec" ++ show i) codec,
            D.text ("var argument" ++ show i ++ " = codec" ++ show i ++ ".encode(value" ++ show i ++ ");")]
          invocation = E.call evaluator (D.text "symbols" : [D.text ("argument" ++ show i) | i <- [0 .. length args - 1]])
          body = installs ++ concat [input i codec | (i,codec) <- zip [0::Int ..] codecs] ++
            [assign "result" invocation,
             assign "resultCodec" resultCodec,
             D.text "return resultCodec.decode(result);"]
      pure (signature <> D.block 2 (contextual (declarationId declaration) (D.joinWith D.hardline body)))
    implementation contracts (index,d) = do
      let args = definitionArguments d
          binders = args ++ nestedBinders (definitionBody d)
          names = [(binderId b,"value" ++ show i) | (i,b) <- zip [0::Int ..] binders]
          local identity = maybe (error "unbound Java definition binder") id (lookup identity names)
          external expression values = case expressionNode expression of
            ExternalCall identity _ | Just name <- lookup identity callees ->
              pure (E.call name (D.text "symbols":values))
            -- handle e with h end: e runs with h installed for its ability,
            -- made afresh each time (a Kotlin handler through its bridge).
            Handle (WithHandler ability (SpecHandler h)) _ | [body] <- values ->
              let made = case [(o, x) | o <- units, x <- unitHandlers o, handlerId x == h] of
                    (o, x) : _ | withNative -> "new " ++ abilitiesClassOf o ++ "." ++ specName x ++ "(symbols)"
                    _ -> "lawspec.runtime.LawSpecKotlinAdapters." ++ kotlinHandlerBridge h ++ "(symbols)"
              in pure (E.call "LawSpecRuntime.withHandlers" [D.text "symbols",
                E.call "java.util.Map.of" [E.quoted (abilityKey ability), D.text made], D.text "() -> " <> body])
            -- raise aborts to the nearest attempt of its Fail ability.
            Perform op [_] | isFail (operationAbility op) ->
              pure (E.call "LawSpecRuntime.raiseFailure" (E.quoted (abilityKey (operationAbility op)) : values))
            -- An operation goes to the handler installed in symbols for its
            -- ability: Java directly, through the codecs; Kotlin through its
            -- generated bridge.
            Perform op args
              | not withNative -> pure (E.call ("lawspec.runtime.LawSpecKotlinAdapters." ++ kotlinOperationBridge op) (D.text "symbols" : values))
              | otherwise -> do
                  codecs <- mapM (Native.javaCodecDocWithContext (D.text "symbols") declarations bits . expressionType) args
                  resultCodec <- Native.javaCodecDocWithContext (D.text "symbols") declarations bits (expressionType expression)
                  let call = E.call (handlerOf (operationAbility op) ++ "." ++ operationName op)
                        [codec <> D.text ".decode(" <> value <> D.text ")" | (codec, value) <- zip codecs values]
                  pure $ if expressionType expression == scalarType "Unit"
                    then E.call "lawspec.runtime.LawSpecRuntime.unit" [D.text "() -> " <> call]
                    else resultCodec <> D.text ".encode(" <> call <> D.text ")"
            -- An orchestration calls an adapter natively: Java directly, with
            -- the codecs; Kotlin through its generated bridge.
            ExternalCall identity _ | Just (owner, adapter) <- lookup identity (orchestratedAdapters units) ->
              if not withNative
                then pure (E.call ("lawspec.runtime.LawSpecKotlinAdapters." ++ kotlinAdapterBridge identity) (D.text "symbols" : values))
                else do
                  let (parameterTypes, resultType) = functionType (declarationType adapter)
                      parts = split '.' (idText owner)
                      cls = intercalate "." (init parts ++ [concatMap capitalize (split '_' (last parts))])
                  codecs <- mapM (Native.javaCodecDocWithContext (D.text "symbols") declarations bits) parameterTypes
                  resultCodec <- Native.javaCodecDocWithContext (D.text "symbols") declarations bits resultType
                  -- An adapter that uses abilities gets their handlers first.
                  let call = E.call (cls ++ "." ++ declarationName adapter)
                        ([D.text (handlerOf a) | a <- declarationUses adapter, not (isFail a)] ++
                         [codec <> D.text ".decode(" <> value <> D.text ")" | (codec, value) <- zip codecs values])
                  -- Within its stage's timeout and hedge, when it has them.
                  pure $ if declarationAsync adapter
                    then E.call "LawSpecRuntime.awaitStep" [D.text "symbols", D.text "() -> " <> call,
                      D.text "_native -> " <> resultCodec <> D.text ".encode(_native)"]
                    -- A Unit adapter is void natively.
                    else failing adapter (if resultType == scalarType "Unit"
                      then E.call "lawspec.runtime.LawSpecRuntime.unit" [D.text "() -> " <> call]
                      else resultCodec <> D.text ".encode(" <> call <> D.text ")")
            _ -> Left "unknown Java definition"
          signature = E.call ("public static Value evaluate" ++ show index)
            (D.text "Map<String, Object> symbols" : [D.text ("Value input" ++ show i) | i <- [0..length args-1]]) <> D.text " "
      -- Arguments and results were checked where they were built, decoded
      -- or drawn; the native wrappers check values crossing from adapters.
      let checks = [assign (local (binderId b)) (D.text ("input" ++ show i)) | (i,b) <- zip [0::Int ..] args]
      rendered <- E.renderExpression declarations bits local external (definitionBody d)
      -- A workflow stage with policies runs under the workflow runtime.
      body <- case definitionPolicy d of
        Nothing -> pure rendered
        Just policy | policyFrame policy ->
          pure (E.call "LawSpecRuntime.runWorkflow" [D.text "symbols", D.text "() -> " <> rendered])
        Just policy -> do
          failures <- forM (stageFailures d) $ \(kind, value) ->
            (\rendered' -> D.text ("case " ++ show kind ++ " -> ") <> rendered' <> D.text ";") <$>
              E.renderExpression declarations bits local external value
          let fail' = if null failures then D.text "null" else D.text "kind -> switch (kind) " <> D.block 2 (D.joinWith D.hardline
                (failures ++ [D.text "default -> throw new IllegalStateException(\"unexpected stage failure: \" + kind);"]))
              key = case args of
                argument : _ -> D.text (local (binderId argument))
                [] -> D.text "null"
          config <- policyDoc (idText (declarationId (definitionDeclaration d))) fail' policy
          pure (E.call "LawSpecRuntime.runStage" [D.text "symbols", config, D.text "() -> " <> rendered, key])
      ref <- E.reference (expressionType (definitionBody d))
      let contract = lookup (declarationId (definitionDeclaration d)) [(contractDeclaration c,c) | c <- contracts]
          validated = const (D.text "result") ref
      statements <- case contract of
        Nothing -> pure (checks ++ [assign "result" body,D.text "return " <> validated <> D.text ";"])
        Just c -> do
          let aliases = zip (map binderId (contractArguments c)) (map (local . binderId) args) ++
                [(binderId (contractResult c),"checkedResult")] ++
                [(binderId b,"contractValue" ++ show i) | (i,b) <- zip [0::Int ..]
                  (concatMap nestedBinders (contractPreconditions c ++ contractPostconditions c ++ contractRuntimePostconditions c))]
              resolve identity = maybe (error "unbound Java definition contract binder") id (lookup identity aliases)
              require stage predicate = do
                expression <- E.renderExpression declarations bits resolve external predicate
                pure (E.call "LawSpecRuntime.requireContract"
                  [E.call "LawSpecRuntime.truth" [expression],E.quoted stage] <> D.text ";")
          pre <- mapM (require "precondition") (contractPreconditions c)
          -- Proved by the totality audit; see LawSpec.Core.Evidence.
          post <- mapM (require "postcondition") (runtimePostconditions c)
          pure (checks ++ pre ++ [assign "result" body,assign "checkedResult" validated] ++
            post ++ [D.text "return checkedResult;"])
      pure (signature <> D.block 2 (contextual (declarationId (definitionDeclaration d))
        (D.joinWith D.hardline statements)))
    evaluator identity = maybe (Left "unresolved Java policy definition") Right (lookup identity callees)
    -- An adapter that fails with E: its native code throws LawSpecRuntime.Fail.
    failing adapter call = case [a | a@(AbilityRef _ [_]) <- declarationUses adapter, isFail a] of
      ability@(AbilityRef _ [failure]) : _ ->
        let codec = either error id (Native.javaCodecDocWithContext (D.text "symbols") declarations bits failure)
            native = either error id (Native.javaDataTypeDoc declarations failure)
        in E.call "LawSpecRuntime.nativeFailures" [E.quoted (abilityKey ability),
             D.text "_native -> " <> codec <> D.text ".encode((" <> native <> D.text ") _native)", D.text "() -> " <> call]
      _ -> call
    -- A handler from symbols, as its ability's Java interface.
    handlerOf ability = "((" ++ maybe "Object" (\(_, a) -> abilitiesClassOfName (ownerName a) ++ "." ++ interfaceName a)
      (findAbility units ability) ++
      ") LawSpecRuntime.handler(symbols, " ++ show (abilityKey ability) ++ "))"
    lowerFirst (c:cs) = toEnum (fromEnum c + (if c >= 'A' && c <= 'Z' then 32 else 0)) : cs
    lowerFirst [] = []
    abilitiesClassOf u = abilitiesClassOfName (idText (unitId u))
    abilitiesClassOfName unit = let parts = split '.' unit
      in intercalate "." ("lawspec" : "abilities" : init parts ++ [concatMap capitalize (split '_' (last parts))])
    policyDoc key fail' policy = do
      gates <- policyGates policy
      compensate <- case policyCompensate policy of
        Nothing -> pure (D.text "null")
        Just undo -> (\name -> D.text ("value -> " ++ name ++ "(symbols, value)")) <$> evaluator undo
      retry <- case policyRetry policy of
        Nothing -> pure (D.text "null")
        Just r -> do
          let (kind, delay, step, factor, cap) = case retryStrategy r of
                Immediate -> ("immediate", 0, 0, 0, -1)
                Fixed d' -> ("fixed", d', 0, 0, -1)
                Linear d' s -> ("linear", d', s, 0, -1)
                Exponential d' f c -> ("exponential", d', 0, f, maybe (-1) id c)
                Fibonacci d' -> ("fibonacci", d', 0, 0, -1)
                Custom _ -> ("custom", 0, 0, 0, -1)
          condition <- case retryWhen r of
            Nothing -> pure (D.text "null")
            Just p -> (\name -> D.text ("failure -> LawSpecRuntime.truth(" ++ name ++ "(symbols, failure))")) <$> evaluator p
          decide <- case retryStrategy r of
            Custom f -> (\name -> D.text ("(attempt, failure, previous) -> LawSpecRuntime.retryDecision(" ++ name ++
              "(symbols, LawSpecRuntime.integer64(attempt), failure, LawSpecRuntime.duration(previous)))")) <$> evaluator f
            _ -> pure (D.text "null")
          pure (E.call "new LawSpecRuntime.Retry"
            [E.quoted kind, long delay, long step, long factor, long cap, long (retryAttempts r), E.quoted (jitterName (retryJitter r)), condition, decide])
      pure (E.call "new LawSpecRuntime.StagePolicy" [E.quoted (policyStage policy), retry, long (maybe (-1) id (policyTimeout policy)),
        E.quoted key, E.call "java.util.List.of" gates, long (maybe (-1) id (policyCache policy)),
        D.text (if null (policyFailures policy) then "false" else "true"), fail', compensate,
        maybe (D.text "null") (\h -> E.call "new LawSpecRuntime.Hedge" [E.quoted (policyStage policy), long (hedgeDelay h), long (hedgeMost h)]) (policyHedge policy)])
    -- A gate's callbacks call the unit's copies of the resilience unit's
    -- state machines, with the policy's numbers.
    policyGates policy = do
      breaker <- forM (policyBreaker policy) $ \b -> do
        start <- evaluator (breakerStart b)
        admit <- evaluator (breakerAdmit b)
        record <- evaluator (breakerRecord b)
        pure (gate "breaker" (start ++ "(symbols, LawSpecRuntime.integer64(now))") (admit ++ "(symbols, state, LawSpecRuntime.integer64(now))")
          (Just (record ++ "(symbols, " ++ integers [breakerFailures b, breakerWindow b, breakerCooldown b] ++
            ", state, LawSpecRuntime.integer64(now), LawSpecRuntime.bool(succeeded))")) (-2))
      limit <- forM (policyLimit policy) $ \l -> do
        start <- evaluator (limitStart l)
        admit <- evaluator (limitAdmit l)
        let numbers = integers [limitCount l, limitPeriod l]
        pure (gate "limit" (start ++ "(symbols, " ++ numbers ++ ", LawSpecRuntime.integer64(now))")
          (admit ++ "(symbols, " ++ numbers ++ ", state, LawSpecRuntime.integer64(now))") Nothing (waitCode (limitWait l)))
      bulkhead <- forM (policyBulkhead policy) $ \b -> do
        start <- evaluator (bulkheadStart b)
        admit <- evaluator (bulkheadAdmit b)
        release <- evaluator (bulkheadRelease b)
        let n = integers [bulkheadLimit b]
        pure (gate "bulkhead" (start ++ "(symbols, " ++ n ++ ", LawSpecRuntime.integer64(now))")
          (admit ++ "(symbols, " ++ n ++ ", state, LawSpecRuntime.integer64(now))") (Just (release ++ "(symbols, state)")) (waitCode (bulkheadWait b)))
      pure (maybe [] pure breaker ++ maybe [] pure limit ++ maybe [] pure bulkhead)
    gate kind start admit finish wait = E.call "new LawSpecRuntime.Gate"
      [E.quoted kind, D.text ("now -> " ++ start), D.text ("(state, now) -> " ++ admit),
       D.text (maybe "null" ("(state, now, succeeded) -> " ++) finish), long wait]
    integers numbers = intercalate ", " ["LawSpecRuntime.integer64(" ++ show n ++ ")" | n <- numbers]
    waitCode wait = case wait of
      Nothing -> -2
      Just Nothing -> -1
      Just (Just d') -> d'
    long n = D.text (show n ++ "L")
    jitterName j = case j of
      NoJitter -> "none"
      FullJitter -> "full"
      EqualJitter -> "equal"
      DecorrelatedJitter -> "decorrelated"
    nestedBinders expression = case expressionNode expression of
      AllElements value binder predicate -> nestedBinders value ++ [binder] ++ nestedBinders predicate
      Let binder value body -> nestedBinders value ++ [binder] ++ nestedBinders body
      AllPayloads value predicates -> nestedBinders value ++ concat
        [binder : nestedBinders predicate | (binder,predicate) <- predicates]
      Match value cases -> nestedBinders value ++ concat
        [caseBinders branch ++ nestedBinders (caseBody branch) | branch <- cases]
      _ -> concatMap nestedBinders (children expression)
    split delimiter value = case break (== delimiter) value of
      (a,[]) -> [a]
      (a,_:rest) -> a : split delimiter rest
    capitalize [] = []
    capitalize (c:cs) = toUpper c : cs
