-- | Native entry points and checked implementation helpers for total definitions.
module LawSpec.JavaDefinitions (emitJavaDefinitions, emitJvmDefinitionBodies, emitScalaDefinitionBodies, definitionCalls, orchestratedAdapters, kotlinAdapterBridge, kotlinOperationBridge, kotlinHandlerBridge, performedOperations, scopedHandlers) where

import LawSpec.JavaText (javaText)
import LawSpec.Core.Stages (stageFailures)
import LawSpec.JvmLets (flattenLets)
import LawSpec.Core.Policy
import Control.Monad (forM)
import Data.Char (isAlphaNum, toUpper)
import Data.List (intercalate, stripPrefix)
import LawSpec.Common
import LawSpec.Core
import LawSpec.Typed.Plan (TypedPlan(..), sharedDefinitions, isContextual)
import qualified Data.Map.Strict as M
import LawSpec.Core.DefinitionContracts (checkedDefinitionContracts)
import LawSpec.Core.Evidence (runtimePostconditions)
import qualified LawSpec.JavaData as Native
import LawSpec.AbilityNames (interfaceName, specName, ownerName)
import qualified LawSpec.JavaExpr as E
import qualified LawSpec.Code.Doc as D
import LawSpec.RuntimeSources (runtimeSource)
import LawSpec.Typed.Jvm (JvmTyped(..), JvmStyle(..), emitJvmTyped, jvmPerformName)
import qualified Data.Set as S
import LawSpec.JvmNames (jvmClaimAll, jvmLocal, jvmLocalTable, jvmReserved, jvmMethod)
import LawSpec.Naming (readableDefinitionName)

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
kotlinAdapterBridge identity = jvmMethod "call" (idText identity)

-- The Kotlin bridge method through which shared JVM bodies perform a Kotlin
-- handler's operation.
kotlinOperationBridge :: Operation -> String
kotlinOperationBridge op = jvmMethod "perform" (idText (operationId op))

-- The Kotlin bridge method through which shared JVM bodies make a Kotlin
-- spec handler, for handle ... with h end.
kotlinHandlerBridge :: Id -> String
kotlinHandlerBridge h = jvmMethod "handler" (idText h)

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
definitionCalls units = [(identity, "lawspec.runtime.LawSpecDefinitionBodies." ++ method) | (identity, method) <- definitionMethods units]

-- | Each checked definition's method, named after the definition (a
-- specialised copy by its argument types), unique in declaration order.
-- ref:DEC-readable-generated-names
definitionMethods :: [Unit] -> [(Id, String)]
definitionMethods units = zip (map (declarationId . definitionDeclaration) definitions)
  (fst (jvmClaimAll (S.fromList (jvmReserved "java" ++ ["result"])) (map readable definitions)))
  where
    definitions = concatMap unitDefinitions units
    readable d = let declaration = definitionDeclaration d
                     (arguments, _) = functionType (declarationType declaration)
                 in jvmLocal "java" [] (readableDefinitionName (declarationName declaration) arguments)

-- | Checked definitions are emitted as ordinary Java code, so adapters and tests call
-- the same proved implementation. ref:DEC-total-definitions
emitJavaDefinitions :: D.Layout -> Int -> [DataDeclaration] -> [Unit] -> Either String [Artifact]
emitJavaDefinitions = emitDefinitions JavaStyle

-- | Kotlin reuses the Java bodies of checked definitions, so the two JVM targets
-- run one implementation.
emitJvmDefinitionBodies :: D.Layout -> Int -> [DataDeclaration] -> [Unit] -> Either String [Artifact]
emitJvmDefinitionBodies = emitDefinitions KotlinStyle

-- | Scala reuses them too, with its own adapter bridge.
emitScalaDefinitionBodies :: D.Layout -> Int -> [DataDeclaration] -> [Unit] -> Either String [Artifact]
emitScalaDefinitionBodies = emitDefinitions ScalaStyle

emitDefinitions :: JvmStyle -> D.Layout -> Int -> [DataDeclaration] -> [Unit] -> Either String [Artifact]
emitDefinitions _ _ _ _ units | null (concatMap unitDefinitions units) = pure []
emitDefinitions style layout bits declarations units = do
  contracts <- checkedDefinitionContracts bits declarations units
  typed <- emitJvmTyped style declarations units
  -- Definitions that are the same up to their names (an import's copies)
  -- share one body; the others call it.
  let shared = sharedDefinitions units
      everyName = M.fromList [(declarationId (definitionDeclaration d), i) | (i, d) <- zip [0::Int ..] (concatMap unitDefinitions units)]
      delegate i d target = pure (E.call ("public static Value " ++ methodName i)
        (D.text "Map<String, Object> symbols" : [D.text ("Value input" ++ show k) | k <- [0 .. length (definitionArguments d) - 1]]) <> D.hardline <>
        D.block 2 (statement (E.call ("return " ++ methodName target) (D.text "symbols" : [D.text ("input" ++ show k) | k <- [0 .. length (definitionArguments d) - 1]]))))
  methods <- mapM (\(i, d) -> case M.lookup (declarationId (definitionDeclaration d)) shared >>= (`M.lookup` everyName) of
      Just target -> delegate i d target
      Nothing -> maybe (implementation contracts (i, d)) (bridge typed i d)
        (jvmTypedFunction typed (declarationId (definitionDeclaration d)))) (zip [0::Int ..] (concatMap unitDefinitions units))
  performs <- typedPerforms typed
  let source = file "lawspec.runtime" "LawSpecDefinitionBodies"
        ["java.util.Map", "lawspec.runtime.LawSpecRuntime.Value"] (methods ++ performs)
      -- The typed definitions and their runtime.
      typedFiles = if null (typedRepresentativesOf typed) then [] else
        [ Artifact "src/main/java/lawspec/runtime/LawSpecTyped.java" (jvmTypedSource typed) "generated" "source"
        , Artifact "src/main/java/lawspec/runtime/LawSpecFast.java" (runtimeSource "java-fast") "generated" "source" ] ++
        [ Artifact "src/main/scala/lawspec/runtime/LawSpecTypedScala.scala" (jvmTypedScalaSource typed) "generated" "source"
        | not (null (jvmTypedScalaSource typed)) ]
  native <- if withNative then mapM (nativeUnit typed) (filter (not . null . unitDefinitions) units) else pure []
  pure (source : typedFiles ++ native)
  where
    -- Each definition's method, by its index in the program.
    methodName i = maybe ("evaluate" ++ show i) snd (lookup i (zip [0 :: Int ..] (definitionMethods units)))
    statement doc = doc <> D.text ";"
    withNative = style == JavaStyle
    -- Kotlin and Scala adapters and handlers are reached through a bridge.
    adaptersObject = if style == ScalaStyle then "lawspec.runtime.LawSpecScalaAdapters." else "lawspec.runtime.LawSpecKotlinAdapters."
    typedRepresentativesOf typed = M.keys (typedDefinitions (jvmTypedPlan typed))
    -- A typed definition's dynamic entry converts its arguments and result.
    bridge typed index d function = do
      let (argTypes, resultType) = functionType (declarationType (definitionDeclaration d))
      codecs <- mapM (jvmTypedCodec typed) argTypes
      resultCodec <- jvmTypedCodec typed resultType
      let signature = E.call ("public static Value " ++ methodName index)
            (D.text "Map<String, Object> symbols" : [D.text ("Value input" ++ show i) | i <- [0 .. length argTypes - 1]]) <> D.hardline
          call = E.call function
            ([D.text "symbols" | isContextual (jvmTypedPlan typed) (declarationId (definitionDeclaration d))] ++
             [E.call (codec ++ ".decode") [D.text ("input" ++ show i)] | (i, codec) <- zip [0 :: Int ..] codecs])
      pure (signature <> D.block 2 (D.text "return " <> E.call (resultCodec ++ ".encode") [call] <> D.text ";"))
    assign name value = D.group (D.text ("var " ++ name ++ " =") <>
      D.nest 4 (D.softline <> value) <> D.text ";")
    contextual identity body = D.text "try" <> D.hardline <> D.block 2 body <> D.hardline <>
      -- A Fail ability's failure passes through, to the attempt that awaits it.
      D.text "catch (lawspec.runtime.LawSpecRuntime.Failure failure)" <> D.hardline <> D.block 2 (D.text "throw failure;") <> D.hardline <>
      D.text "catch (RuntimeException error)" <> D.hardline <>
      D.block 2 (assign "context" (E.quoted (idText identity ++ ": ")) <> D.hardline <>
        D.text "throw " <> E.call "new IllegalArgumentException"
          [D.text "context + error.getMessage()",D.text "error"] <> D.text ";")
    callees = definitionCalls units
    file package name imports methods = Artifact
      ("src/main/java/" ++ map (\c -> if c == '.' then '/' else c) package ++ "/" ++ name ++ ".java")
      -- This package's classes need no qualifier.
      (D.render layout (D.text "// Generated by LawSpec. Do not edit." <> D.hardline <> D.hardline <>
        D.text ("package " ++ package ++ ";") <> D.hardline <> D.hardline <>
        D.joinWith D.hardline [D.text ("import " ++ item ++ ";") | item <- imports] <>
        D.hardline <> D.hardline <> D.text ("public final class " ++ name) <> D.hardline <>
        D.block 2 (D.mapText (samePackage package) $ D.joinWith (D.hardline <> D.hardline)
          ([D.text ("private " ++ name ++ "()") <> D.hardline <> D.text "{" <> D.hardline <> D.text "}",
            D.text "private static final lawspec.runtime.LawSpecSchema SCHEMA =" <>
              D.nest 4 (D.hardline <> D.text "lawspec.runtime.LawSpecDataSchema.create();")] ++ methods)) <> D.hardline))
      "generated" "source"
    nativeUnit typed unit = do
      let parts = split '.' (idText (unitId unit))
          name = concatMap capitalize (split '_' (last parts))
          package = intercalate "." ("lawspec" : "definitions" : init parts)
      methods <- mapM (native typed) (unitDefinitions unit)
      pure (file package name ["java.util.Map"] methods)
    -- A typed definition whose types all convert directly calls its typed
    -- method between the conversions.
    native typed d
      | Just function <- jvmTypedFunction typed (declarationId (definitionDeclaration d))
      , not (isContextual (jvmTypedPlan typed) (declarationId (definitionDeclaration d)))
      , let (args, result) = functionType (declarationType (definitionDeclaration d))
      , result /= scalarType "Unit"
      , Just conversions <- mapM (jvmTypedNative typed) args
      , Just (_, toNative) <- jvmTypedNative typed result = do
          nativeArgs <- mapM (Native.javaDataTypeDoc declarations) args
          nativeResult <- Native.javaDataTypeDoc declarations result
          let declaration = definitionDeclaration d
              parameters = D.text "Map<String, Object> symbols" : [ty <> D.text (" value" ++ show i) | (i, ty) <- zip [0::Int ..] nativeArgs]
          pure (D.group (D.text "public static " <> nativeResult <> D.text (" " ++ apiName declaration ++ "(") <>
              D.nest 4 (D.softbreak <> D.group (D.commaSep parameters)) <> D.text ")") <> D.hardline <>
            D.block 2 (D.text "return " <> E.call toNative [E.call function
              [E.call fromNative [D.text ("value" ++ show i)] | (i, (fromNative, _)) <- zip [0 :: Int ..] conversions]] <> D.text ";"))
      | otherwise = nativeDynamic d
    -- A definition's method: its name as Google Java Style writes it
    -- (nOfStack is nofStack).
    apiName declaration = jvmLocal "java" [] (declarationName declaration)
    nativeDynamic d = do
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
            E.call "java.util.Map.<String, Object>of" (concat [[E.quoted (abilityKey ability), D.text name] | (ability, name, _) <- handlers])] <> D.text ";"
            | not (null handlers)]
          opening = "public static " ++ D.render D.Compact nativeResult ++ " " ++ apiName declaration ++ "("
          normalSignature = D.group (D.text "public static " <> nativeResult <>
            D.text (" " ++ apiName declaration ++ "(") <>
            D.nest 4 (D.softbreak <> D.group (D.commaSep parameters)) <> D.text ")")
          wrappedSignature = D.text "public static " <> nativeResult <>
            D.nest 4 (D.hardline <> D.text (apiName declaration ++ "(") <>
              D.nest 4 (D.softbreak <> D.group (D.commaSep parameters)) <> D.text ")")
          signature = D.prefixChoice opening normalSignature wrappedSignature
          input i codec = [assign ("codec" ++ show i) codec,
            D.text ("var argument" ++ show i ++ " = codec" ++ show i ++ ".encode(value" ++ show i ++ ");")]
          invocation = E.call evaluator (D.text "symbols" : [D.text ("argument" ++ show i) | i <- [0 .. length args - 1]])
          body = installs ++ concat [input i codec | (i,codec) <- zip [0::Int ..] codecs] ++
            [assign "result" invocation,
             assign "resultCodec" resultCodec,
             D.text "return resultCodec.decode(result);"]
      pure (signature <> D.hardline <> D.block 2 (contextual (declarationId declaration) (D.joinWith D.hardline body)))
    implementation contracts (index,d0) = do
      let d = d0 { definitionBody = freshenShadowed (flattenLets (definitionBody d0)) }
          args = definitionArguments d
          binders = args ++ nestedBinders (definitionBody d)
          -- Binders keep their source names.
          names = jvmLocalTable "java" (jvmReserved "java" ++ ["result", "checkedResult", "failure", "kind"]) binders
          local identity = maybe (error "unbound Java definition binder") id (M.lookup identity names)
          external expression values = case expressionNode expression of
            ExternalCall identity _ | Just name <- lookup identity callees ->
              pure (E.call name (D.text "symbols":values))
            -- handle e with h end: e runs with h installed for its ability,
            -- made afresh each time (a Kotlin handler through its bridge).
            Handle (WithHandler ability (SpecHandler h)) _ | [body] <- values ->
              let made = case [(o, x) | o <- units, x <- unitHandlers o, handlerId x == h] of
                    (o, x) : _ | withNative -> "new " ++ abilitiesClassOf o ++ "." ++ specName x ++ "(symbols)"
                    _ -> adaptersObject ++ kotlinHandlerBridge h ++ "(symbols)"
              in pure (E.call "LawSpecRuntime.withHandlers" [D.text "symbols",
                E.call "java.util.Map.<String, Object>of" [E.quoted (abilityKey ability), D.text made], D.text "() -> " <> body])
            -- raise aborts to the nearest attempt of its Fail ability.
            Perform op [_] | isFail (operationAbility op) ->
              pure (E.call "LawSpecRuntime.raiseFailure" (E.quoted (abilityKey (operationAbility op)) : values))
            -- An operation goes to the handler installed in symbols for its
            -- ability: Java directly, through the codecs; Kotlin through its
            -- generated bridge.
            Perform _ _ -> performDoc expression values
            -- prelude.attempt e: Right of e's value, or Left of its failure.
            Handle (CatchFailure ability) _ | [body] <- values, Constructor "Either" [TypeArgument failure, TypeArgument result] <- expressionType expression -> do
              let placeholder = Id "lawspec::attempt::value"
                  side tag ty = do
                    made <- E.renderExpression declarations bits (\i -> if i == placeholder then "value" else local i) external
                      (Expr (expressionType expression) (Construct (Id tag) [Expr ty (Local placeholder) (GeneratedFrom placeholder)]) (GeneratedFrom placeholder))
                    pure (D.text "value -> " <> made)
              right <- side "Either::Right" result
              left <- side "Either::Left" failure
              pure (E.call "LawSpecRuntime.attempt" [E.quoted (abilityKey ability), D.text "() -> " <> body, right, left])
            -- An orchestration calls an adapter natively: Java directly, with
            -- the codecs; Kotlin through its generated bridge.
            ExternalCall identity _ | Just (owner, adapter) <- lookup identity (orchestratedAdapters units) ->
              if not withNative
                then pure (E.call (adaptersObject ++ kotlinAdapterBridge identity) (D.text "symbols" : values))
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
                      -- A Unit adapter's future completes with nothing (Void).
                      if resultType == scalarType "Unit"
                        then D.text "nativeValue -> lawspec.runtime.LawSpecRuntime.unit(() -> {})"
                        else D.text "nativeValue -> " <> resultCodec <> D.text ".encode(nativeValue)"]
                    -- A Unit adapter is void natively.
                    else failing adapter (if resultType == scalarType "Unit"
                      then E.call "lawspec.runtime.LawSpecRuntime.unit" [D.text "() -> " <> call]
                      else D.group (resultCodec <> D.nest 4 (D.softbreak <> E.call ".encode" [call])))
            _ -> Left "unknown Java definition"
          signature = E.call ("public static Value " ++ methodName index)
            (D.text "Map<String, Object> symbols" : [D.text ("Value input" ++ show i) | i <- [0..length args-1]]) <> D.hardline
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
          let fail' = if null failures then D.text "null" else D.text "kind -> switch (kind)" <> D.hardline <> D.block 2 (D.joinWith D.hardline
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
    -- An operation goes to the handler installed in symbols for its
    -- ability: Java directly, through the codecs; Kotlin through its
    -- generated bridge.
    performDoc expression values = case expressionNode expression of
      Perform op args
        | not withNative -> pure (E.call (adaptersObject ++ kotlinOperationBridge op) (D.text "symbols" : values))
        | otherwise -> do
            codecs <- mapM (Native.javaCodecDocWithContext (D.text "symbols") declarations bits . expressionType) args
            resultCodec <- Native.javaCodecDocWithContext (D.text "symbols") declarations bits (expressionType expression)
            let call = D.group (handlerDoc (operationAbility op) <> D.nest 4 (D.softbreak <> E.call ("." ++ operationName op)
                  [E.call (D.render D.Compact codec ++ ".decode") [value] | (codec, value) <- zip codecs values]))
            -- An operation that fails with E: a native handler throws
            -- LawSpecRuntime.Fail with a native E, which becomes the failure.
            pure $ failingAs (maybe [] pure (findAbility units (operationAbility op) >>= lookup (operationName op) . abilityFailures . snd)) $
              if expressionType expression == scalarType "Unit"
              then E.call "lawspec.runtime.LawSpecRuntime.unit" [D.text "() -> " <> call]
              else D.group (resultCodec <> D.nest 4 (D.softbreak <> E.call ".encode" [call]))
      _ -> Left "not an operation"
    -- The operations typed definitions perform, each a method over dynamic
    -- values that typed code calls.
    typedPerforms typed = do
      let plan = jvmTypedPlan typed
          operations = M.elems (M.fromList [ (operationId op, e) | d <- M.elems (typedDefinitions plan), e <- performedIn (definitionBody d)
                                           , Perform op _ <- [expressionNode e] ])
      forM operations $ \e -> case expressionNode e of
        Perform op args -> do
          let values = [D.text ("input" ++ show k) | k <- [0 .. length args - 1]]
          body <- performDoc e values
          pure (E.call ("public static Value " ++ jvmPerformName op) (D.text "Map<String, Object> symbols" : [D.text "Value " <> v | v <- values]) <> D.hardline <>
            D.block 2 (D.text "return " <> body <> D.text ";"))
        _ -> Left "not an operation"
    performedIn e = case expressionNode e of
      Perform op args | not (isFail (operationAbility op)) -> e : concatMap performedIn args
      _ -> concatMap performedIn (children e)
    failing adapter = failingAs [a | a@(AbilityRef _ [_]) <- declarationUses adapter, isFail a]
    failingAs failures call = case failures of
      ability@(AbilityRef _ [failure]) : _ ->
        let codec = either error id (Native.javaCodecDocWithContext (D.text "symbols") declarations bits failure)
            native = either error id (Native.javaDataTypeDoc declarations failure)
        in E.call "LawSpecRuntime.nativeFailures" [E.quoted (abilityKey ability),
             D.text "nativeValue -> " <> codec <> D.text ".encode((" <> native <> D.text ") nativeValue)", D.text "() -> " <> call]
      _ -> call
    -- A handler from symbols, as its ability's Java interface.
    -- The handler installed for an ability, as its native interface.
    handlerDoc ability = case findAbility units ability of
      Just (_, a) -> E.call "LawSpecRuntime.handler"
        [D.text "symbols", E.quoted (abilityKey ability), D.text (abilitiesClassOfName (ownerName a) ++ "." ++ interfaceName a ++ ".class")]
      Nothing -> E.call "LawSpecRuntime.handler" [D.text "symbols", E.quoted (abilityKey ability)]
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
      [E.quoted kind, javaText ("now -> " ++ start), javaText ("(state, now) -> " ++ admit),
       javaText (maybe "null" ("(state, now, succeeded) -> " ++) finish), long wait]
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

-- | Java forbids a local that shadows another in scope, even inside a
-- lambda, so a binder rebound inside its own scope (a lowering may repeat
-- one) gets an identity of its own there.
freshenShadowed :: Expr -> Expr
freshenShadowed = go S.empty
  where
    go scope e = case expressionNode e of
      Let binder value body ->
        let (binder', body') = fresh scope binder body
            inner = S.insert (binderId binder') scope
        in e { expressionNode = Let binder' (go inner value) (go inner body') }
      Match value cases ->
        e { expressionNode = Match (go scope value)
          [ let (binders, body) = foldr (\b (bs, bd) -> let (b', bd') = fresh scope b bd in (b' : bs, bd')) ([], caseBody c) (caseBinders c)
            in c { caseBinders = binders, caseBody = go (foldr (S.insert . binderId) scope binders) body }
          | c <- cases ] }
      _ -> mapChildren (go scope) e
    fresh scope binder body
      | binderId binder `S.member` scope =
          let renamed = Id (idText (binderId binder) ++ "::shadow::" ++ show (S.size scope))
          in (binder { binderId = renamed }, renameLocal (binderId binder) renamed body)
      | otherwise = (binder, body)

-- | Text with a class of the given package named without its package (not
-- the package line itself, whose text has no class after it).
samePackage :: String -> String -> String
samePackage package text = go text
  where
    prefix = package ++ "."
    go s = case s of
      [] -> []
      _ | Just rest@(c : _) <- stripPrefix prefix s, c `elem` ['A' .. 'Z'] -> go rest
      c : rest -> c : go rest
