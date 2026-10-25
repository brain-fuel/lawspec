-- | Native public JS/TS entry points over framework-independent checked bodies.
module LawSpec.WebDefinitions (emitWebDefinitions, emitWebDefinitionsWithNativeBridge, definitionCalls, definitionNames, plainCall) where

import Control.Monad (forM)
import LawSpec.Core.Policy
import LawSpec.Core
import LawSpec.Core.DefinitionContracts (checkedDefinitionContracts)
import LawSpec.Core.Evidence (runtimePostconditions)
import LawSpec.Common (Artifact(..))
import qualified LawSpec.WebData as Native
import qualified LawSpec.WebExpr as X
import qualified LawSpec.Code.ECMAScript as E
import qualified LawSpec.Code.Doc as D
import Data.List (nub, sort, stripPrefix, isPrefixOf)
import Data.Char (toLower)
import LawSpec.AbilityNames (specName, interfaceName, ownerName)
import LawSpec.RuntimeSources (runtimeSource)
import LawSpec.Typed.Web (WebTyped(..), emitWebTyped)
import LawSpec.Typed.Plan (TypedPlan(..))
import LawSpec.WebTypes (namesFor)
import LawSpec.WebModule (Support(..), webModule, linkComment, printWebModule, importExtension)
import LawSpec.Naming (claimAll, scopeWith, nativeIdentifier, localIdentifier, NameKind(..), readableDefinitionName, sourceDefinitionName)
import LawSpec.SourceLink (sourceLink)
import qualified Data.Map.Strict as M
import qualified Data.Set as Set

-- | Generated tests call checked definitions by these names, so every test
-- file agrees. An asynchronous definition's call is marked "await ", so
-- callers await it.
definitionCalls :: [DataDeclaration] -> [Unit] -> [(Id,String)]
definitionCalls declarations units =
  [(identity, (if identity `elem` waiting then "await " else "") ++ "_definitions." ++ name) | (identity, name) <- definitionNames declarations units]
  where waiting = asyncDefinitions units

-- | A definition's function is named after it (LawSpec.Naming), with _2
-- only when two definitions would share a name.
definitionNames :: [DataDeclaration] -> [Unit] -> [(Id,String)]
definitionNames declarations units = zip (map (declarationId . definitionDeclaration) definitions)
  (fst (claimAll (scopeWith (X.webReserved ++ moduleNames)) (map base definitions)))
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
      in nativeIdentifier "javascript" FunctionName
           (readableDefinitionName (declarationName declaration) (map display (fst (functionType (declarationType declaration)))))
    moduleNames = ["data", "ls", "schema", "result", "checkedResult", "lsf"]

-- | Workflows (and their stages) that call an asynchronous adapter, directly or
-- through another such definition, are async functions.
asyncDefinitions :: [Unit] -> [Id]
asyncDefinitions units = grow []
  where
    definitions = concatMap unitDefinitions units
    definitionIds = map (declarationId . definitionDeclaration) definitions
    asyncAdapters = [declarationId d | u <- units, d <- unitDeclarations u, declarationAsync d, declarationId d `notElem` definitionIds]
    callsIn expression = case expressionNode expression of
      ExternalCall callee arguments -> callee : concatMap callsIn arguments
      _ -> concatMap callsIn (children expression)
    grow known =
      let next = nub [ declarationId (definitionDeclaration d) | d <- definitions, definitionOrchestrates d
                     , any (\callee -> callee `elem` asyncAdapters || callee `elem` known) (callsIn (definitionBody d)) ]
      in if sort next == sort known then known else grow next

-- | A definition call's function, without its await mark.
plainCall :: String -> String
plainCall name = maybe name id (stripPrefix "await " name)

-- | Checked definitions are emitted as ordinary JavaScript and TypeScript code, so adapters and tests call
-- the same proved implementation. ref:DEC-total-definitions
emitWebDefinitions :: Bool -> D.Layout -> Int -> [DataDeclaration] -> [Unit] -> Either String [Artifact]
emitWebDefinitions = emitWebDefinitionsWithNativeBridge False

-- | Native registration is an explicit side-effect import in the module AST.
emitWebDefinitionsWithNativeBridge :: Bool -> Bool -> D.Layout -> Int -> [DataDeclaration] -> [Unit] -> Either String [Artifact]
emitWebDefinitionsWithNativeBridge _ _ _ _ _ units | null (concatMap unitDefinitions units) = pure []
emitWebDefinitionsWithNativeBridge nativeBridge ts layout bits declarations units = do
  contracts <- checkedDefinitionContracts bits declarations units
  typed <- emitWebTyped ts bits declarations units
  bodies <- mapM (\d -> maybe (implementation contracts d) (bridge typed d)
      (webTypedFunction typed (declarationId (definitionDeclaration d))))
    (concatMap unitDefinitions units)
  wrappers <- mapM nativeUnit (filter (not . null . unitDefinitions) units)
  let hasTyped = not (M.null (typedDefinitions (webTypedPlan typed)))
      typedFiles = if hasTyped
        then [ Artifact ("src/lawspec_typed." ++ extension) (webTypedModule typed) "generated" "source"
             , Artifact ("src/lawspec_fast." ++ extension) (if ts then "// @ts-nocheck\n" ++ replaceText "./lawspec_runtime.mjs" "./lawspec_runtime.js" (runtimeSource "web-fast") else runtimeSource "web-fast") "generated" "source" ]
        else []
  pure (file True ("src/lawspec_definition_bodies." ++ extension) "./"
    (adapterImports ++ [("_typed", E.ImportDecl False (E.ImportNamespace "_typed") ("./lawspec_typed." ++ importExtension ts)) | hasTyped]) bodies : wrappers ++ typedFiles)
  where
    replaceText old new text = case text of
      [] -> []
      _ | take (length old) text == old -> new ++ replaceText old new (drop (length old) text)
      c : rest -> c : replaceText old new rest
    names = definitionNames declarations units
    functionNameOf d = maybe "unnamed" id (lookup (declarationId (definitionDeclaration d)) names)
    -- Each function's comment links it to its definition.
    linked d stmt = let declaration = definitionDeclaration d
      in [linkComment (sourceDefinitionName (declarationName declaration)) (sourceLink (declarationOrigin declaration)), stmt]
    -- A definition's arguments keep their source names.
    argumentNames d = fst (claimAll (scopeWith (X.webReserved ++ ["result", "checkedResult"]))
      [localIdentifier "javascript" (binderName b) | b <- definitionArguments d])
    -- A typed definition's dynamic entry converts its arguments and result.
    bridge typed d function = do
      let (argTypes, resultType) = functionType (declarationType (definitionDeclaration d))
          identity = declarationId (definitionDeclaration d)
          arguments = argumentNames d
          needsContext = identity `Set.member` typedContextual (webTypedPlan typed)
          invocation = E.call ("_typed." ++ webTypedTo typed resultType) [E.call ("_typed." ++ function)
            ([E.Ident "symbols" | needsContext] ++ [E.call ("_typed." ++ webTypedFrom typed t) [E.Ident a] | (t, a) <- zip argTypes arguments])]
      pure (linked d (E.FunctionDecl True False (functionNameOf d) [] (symbols : [annotated a unknownType | a <- arguments]) (annotation unknownType)
        [contextual identity [E.ret invocation]]))
    extension = if ts then "ts" else "mjs"
    width = X.machineBits
    unknownType = E.TKeyword "unknown"
    annotated name ty = (E.param name) { E.paramType = if ts then Just ty else Nothing }
    annotation ty = if ts then Just ty else Nothing
    callees = definitionCalls declarations units
    definitionIds = map (declarationId . definitionDeclaration) (concatMap unitDefinitions units)
    adapters = [(declarationId d, (idText (unitId u), d)) | u <- units, d <- unitDeclarations u,
      declarationId d `notElem` definitionIds]
    -- The adapter modules orchestrations call, imported from the bodies file.
    adapterAlias owner = "_adapters_" ++ map (\c -> if c == '.' then '_' else c) owner
    adapterImports = nub [ (adapterAlias owner, E.ImportDecl False (E.ImportNamespace (adapterAlias owner))
                             ("./" ++ map (\c -> if c == '.' then '/' else c) owner ++ "." ++ importExtension ts))
                         | d <- concatMap unitDefinitions units, definitionOrchestrates d
                         , callee <- calls (definitionBody d), Just (owner, _) <- [lookup callee adapters] ] ++
      -- The spec handlers that handle ... with h end regions make.
      nub [ (abilitiesAlias owner, E.ImportDecl False (E.ImportNamespace (abilitiesAlias owner))
              ("./lawspec_abilities/" ++ map (\c -> if c == '.' then '/' else c) owner ++ "." ++ importExtension ts))
          | d <- concatMap unitDefinitions units, h <- scopedHandlers (definitionBody d), Just (owner, _) <- [specHandlerOwner h] ]
    abilitiesAlias owner = "_abilities_" ++ map (\c -> if c == '.' then '_' else c) owner
    scopedHandlers expression = case expressionNode expression of
      Handle (WithHandler _ (SpecHandler h)) body -> h : scopedHandlers body
      _ -> concatMap scopedHandlers (children expression)
    specHandlerOwner h = case [(idText (unitId o), x) | o <- units, x <- unitHandlers o, handlerId x == h] of
      found : _ -> Just found
      [] -> Nothing
    calls expression = case expressionNode expression of
      ExternalCall callee arguments -> callee : concatMap calls arguments
      _ -> concatMap calls (children expression)
    -- A module of functions: its imports and support are those it uses.
    file loadsHandlers path root imports functions = Artifact path (printWebModule layout ts (webModule ts
      [E.Comment ["// Generated by LawSpec. Do not edit."]]
      (imports ++ concat
        [[(alias, E.ImportDecl False (E.ImportNamespace alias) (root ++ moduleName ++ "." ++ importExtension ts))] ++
          [(alias, E.ImportDecl False E.ImportEffect (root ++ "lawspec_native." ++ importExtension ts))
          | nativeBridge && loadsHandlers && alias == "ls"]
        | (alias, moduleName) <- [("data","lawspec_data"),("ls","lawspec_runtime"),("schema","lawspec_schema")]])
      [ Support "_lawspec_schema" [E.constDecl "_lawspec_schema" (E.call "data.makeSchema" [])]
      , Support "MACHINE_BITS" (X.machineBitsDeclaration bits) ]
      functions)) "generated" "source"
    -- A failure raised with Fail passes through, to the attempt that awaits it.
    contextual identity body = E.Try body (Just (Just (E.PIdent "error"),
      [ E.IfSingle (E.Binary "instanceof" (E.Ident "error") (E.member (E.Ident "ls") "Failure")) (E.Throw (E.Ident "error"))
      , E.Throw (E.new' "globalThis.Error"
          [E.Binary "+" (E.Str (idText identity ++ ": ")) (E.call "globalThis.String" [E.Ident "error"]),
           E.Object [E.Prop (E.KName "cause") (E.Ident "error")]]) ])) Nothing
    schemaCall name ty value = do
      ref <- Native.webTypeReference ty
      pure (E.call ("_lawspec_schema." ++ name) [ref,value,width,E.Ident "symbols"])
    -- A handler's values cross with the handler schema (ls.handlerSchema).
    handlerCall name ty value = do
      ref <- Native.webTypeReference ty
      pure (E.method (E.call "ls.handlerSchema" [E.Ident "_lawspec_schema"]) name [ref,value,width,E.Ident "symbols"])
    symbols = annotated "symbols" (E.TRef "Map" [E.TKeyword "string", E.TKeyword "symbol"])
    failureCallback convert = E.arrow [annotated "_failure" unknownType] convert
    implementation contracts d = do
      let binders = definitionArguments d
          arguments = argumentNames d
          locals = zip (map binderId binders) arguments
          local identity = maybe (error "unresolved JS/TS local") id (lookup identity locals)
          asynchronous = declarationId (definitionDeclaration d) `elem` asyncDefinitions units
          awaitIf condition expression = if condition then E.Await expression else expression
          external term values = case expressionNode term of
            -- raise aborts to the nearest attempt of its Fail ability.
            Perform op [_] | isFail (operationAbility op) ->
              pure (E.call "ls.raiseFailure" (E.Str (abilityKey (operationAbility op)) : values))
            -- An operation goes to the handler installed in symbols for its
            -- ability (evidence passing).
            Perform op args -> do
              nativeValues <- sequence [handlerCall "toNative" (expressionType a) value | (a, value) <- zip args values]
              let invocation = E.method (E.call "ls.handler" [E.Ident "symbols", E.Str (abilityKey (operationAbility op))]) (operationName op) nativeValues
              result <- if expressionType term == Constructor "Unit" []
                then pure (E.call "ls.unitResult" [invocation])
                else handlerCall "fromNative" (expressionType term) invocation
              -- An operation that fails with E: a native handler throws
              -- ls.Fail with a native E, which becomes the failure.
              case findAbility units (operationAbility op) >>= lookup (operationName op) . abilityFailures . snd of
                Just failing@(AbilityRef _ [failure]) -> do
                  convert <- handlerCall "fromNative" failure (E.Ident "_failure")
                  pure (E.call "ls.nativeFailures" [E.Str (abilityKey failing), failureCallback convert, E.arrow [] result, E.Array []])
                _ -> pure result
            -- prelude.attempt e: Right of e's value, or Left of its failure.
            Handle (CatchFailure ability) _ | [body] <- values ->
              pure (E.call "ls.attempt" [E.Str (abilityKey ability), E.arrow [] body,
                E.arrow [annotated "_value" unknownType] (E.call "ls.construct" [E.Str "Either::Right", E.Array [E.Ident "_value"]]),
                E.arrow [annotated "_value" unknownType] (E.call "ls.construct" [E.Str "Either::Left", E.Array [E.Ident "_value"]])])
            -- handle e with h end: e runs with h installed for its ability,
            -- made afresh each time.
            Handle (WithHandler ability (SpecHandler h)) _ | [body] <- values, Just (owner, x) <- specHandlerOwner h ->
              pure (E.call "ls.withHandlers" [E.Ident "symbols",
                E.Object [E.Prop (E.KString (abilityKey ability)) (E.new' (abilitiesAlias owner ++ "." ++ specName x) [E.Ident "symbols"])],
                E.arrow [] body])
            ExternalCall identity _ | Just name <- lookup identity callees ->
              pure (awaitIf ("await " `isPrefixOf` name)
                (E.call (drop (length ("_definitions." :: String)) (plainCall name)) (E.Ident "symbols":values)))
            -- An orchestration calls an adapter natively: the values cross
            -- to native and back through the schema, as in the tests.
            ExternalCall identity _ | Just (owner, adapter) <- lookup identity adapters -> do
              let (parameterTypes, resultType) = functionType (declarationType adapter)
              nativeValues <- sequence [schemaCall "toNative" ty value | (ty, value) <- zip parameterTypes values]
              -- An adapter that uses abilities gets their handlers first.
              let handlers = [E.call "ls.handler" [E.Ident "symbols", E.Str (abilityKey a)] | a <- declarationUses adapter, not (isFail a)]
                  called = awaitIf (declarationAsync adapter) (E.call (adapterAlias owner ++ "." ++ declarationName adapter) (handlers ++ nativeValues))
              -- A Unit adapter returns undefined, which is the Unit value.
              result <- if resultType == Constructor "Unit" []
                then pure (E.call "ls.unitResult" [called])
                else schemaCall "fromNative" resultType called
              -- An adapter that fails with E: native code throws ls.Fail.
              case [a | a@(AbilityRef _ [_]) <- declarationUses adapter, isFail a] of
                ability@(AbilityRef _ [failure]) : _ | not (declarationAsync adapter) -> do
                  convert <- schemaCall "fromNative" failure (E.Ident "_failure")
                  pure (E.call "ls.nativeFailures" [E.Str (abilityKey ability), failureCallback convert, E.arrow [] result, E.Array []])
                -- An async adapter's rejected promise fails the same way.
                ability@(AbilityRef _ [failure]) : _ -> do
                  convert <- schemaCall "fromNative" failure (E.Ident "_failure")
                  pure (awaitIf True (E.call "ls.nativeFailuresAsync" [E.Str (abilityKey ability), failureCallback convert,
                    E.asyncArrow [] result, E.Array []]))
                _ -> pure result
            _ -> Left "unresolved JS/TS total call"
      rendered <- (if asynchronous then X.renderAsyncExpression else X.renderExpression) ts declarations local external (definitionBody d)
      -- A workflow stage with policies runs under the workflow runtime.
      body <- case definitionPolicy d of
        Nothing -> pure rendered
        Just policy | policyFrame policy -> pure (awaitIf asynchronous (E.call (if asynchronous then "ls.runWorkflowAsync" else "ls.runWorkflow")
          [E.Ident "symbols", E.Arrow asynchronous [] Nothing (E.ExpressionBody rendered)]))
        Just policy -> do
          config <- policyDoc (idText (declarationId (definitionDeclaration d))) policy
          let key = case definitionArguments d of
                argument : _ -> E.Ident (local (binderId argument))
                [] -> E.Null
          pure (awaitIf asynchronous (E.call (if asynchronous then "ls.runStageAsync" else "ls.runStage")
            [E.Ident "symbols", config, E.Arrow asynchronous [] Nothing (E.ExpressionBody rendered), key]))
      -- Arguments and results were checked where they were built, decoded
      -- or drawn; the native wrappers check values crossing from adapters.
      let contract = lookup (declarationId (definitionDeclaration d)) [(contractDeclaration c,c) | c <- contracts]
      statements <- case contract of
        Nothing -> pure [E.ret body]
        Just c -> do
          let aliases = zip (map binderId (contractArguments c))
                (map (local . binderId) (definitionArguments d)) ++
                [(binderId (contractResult c),"checkedResult")]
              resolve identity = maybe (error "unbound definition contract binder") id (lookup identity aliases)
              require stage predicate = do
                expression <- X.renderExpression ts declarations resolve external predicate
                pure (E.ExprStmt (E.call "ls.requireContract" [expression,E.Str stage]))
          pre <- mapM (require "precondition") (contractPreconditions c)
          -- Proved by the totality audit; see LawSpec.Core.Evidence.
          post <- mapM (require "postcondition") (runtimePostconditions c)
          pure (pre ++ [E.constDecl "checkedResult" body] ++ post ++ [E.ret (E.Ident "checkedResult")])
      pure (linked d (E.FunctionDecl True asynchronous (functionNameOf d) [] (symbols : [annotated a unknownType | a <- arguments])
        (annotation (if asynchronous then E.TRef "Promise" [unknownType] else unknownType))
        [contextual (declarationId (definitionDeclaration d)) statements]))
    evaluator identity = maybe (Left "unresolved JS/TS policy definition") (Right . drop (length ("_definitions." :: String)) . plainCall)
      (lookup identity callees)
    anyParam p = annotated p (E.TKeyword "any")
    callTo name args = E.call name (E.Ident "symbols" : args)
    policyDoc key policy = do
      gates <- policyGates policy
      compensate <- case policyCompensate policy of
        Nothing -> pure E.Null
        Just undo -> (\name -> E.arrow [anyParam "value"] (callTo name [E.Ident "value"])) <$> evaluator undo
      retry <- case policyRetry policy of
        Nothing -> pure E.Null
        Just r -> do
          strategy <- case retryStrategy r of
            Immediate -> pure (E.Array [E.Str "immediate"])
            Fixed delay -> pure (E.Array [E.Str "fixed", big delay])
            Linear delay step -> pure (E.Array [E.Str "linear", big delay, big step])
            Exponential delay factor cap -> pure (E.Array [E.Str "exponential", big delay, big factor, maybe E.Null big cap])
            Fibonacci delay -> pure (E.Array [E.Str "fibonacci", big delay])
            Custom decide -> do
              name <- evaluator decide
              pure (E.Array [E.Str "custom", E.arrow (map anyParam ["attempt", "error", "previous"]) (E.call "ls.retryDecision"
                [callTo name [E.Ident "attempt", E.Ident "error", E.new' "ls.DataValue" [E.Str "lawspec.time::type::Duration::Duration", E.Array [E.Ident "previous"]]]])])
          condition <- case retryWhen r of
            Nothing -> pure E.Null
            Just p -> (\name -> E.arrow [anyParam "error"] (callTo name [E.Ident "error"])) <$> evaluator p
          pure (object [("strategy", strategy), ("attempts", big (retryAttempts r)), ("jitter", E.Str (jitterName (retryJitter r))), ("when", condition)])
      pure (object [("stage", E.Str (policyStage policy)), ("retry", retry), ("timeout", maybe E.Null big (policyTimeout policy)),
        ("key", E.Str key), ("gates", E.Array gates), ("cache", maybe E.Null big (policyCache policy)),
        ("wraps", E.BoolLit (not (null (policyFailures policy)))), ("compensate", compensate),
        ("hedge", maybe E.Null (\h -> E.Array [big (hedgeDelay h), big (hedgeMost h)]) (policyHedge policy))])
    -- A gate's callbacks call the unit's copies of the resilience unit's
    -- state machines, with the policy's numbers.
    policyGates policy = do
      breaker <- forM (policyBreaker policy) $ \b -> do
        start <- evaluator (breakerStart b)
        admit <- evaluator (breakerAdmit b)
        record <- evaluator (breakerRecord b)
        pure (object [("kind", E.Str "breaker"), ("start", E.arrow [anyParam "now"] (callTo start [E.Ident "now"])),
          ("admit", E.arrow (map anyParam ["state", "now"]) (callTo admit [E.Ident "state", E.Ident "now"])),
          ("finish", E.arrow (map anyParam ["state", "now", "succeeded"]) (callTo record
            (map big [breakerFailures b, breakerWindow b, breakerCooldown b] ++ map E.Ident ["state", "now", "succeeded"]))),
          ("wait", E.Null)])
      limit <- forM (policyLimit policy) $ \l -> do
        start <- evaluator (limitStart l)
        admit <- evaluator (limitAdmit l)
        let numbers = map big [limitCount l, limitPeriod l]
        pure (object [("kind", E.Str "limit"), ("start", E.arrow [anyParam "now"] (callTo start (numbers ++ [E.Ident "now"]))),
          ("admit", E.arrow (map anyParam ["state", "now"]) (callTo admit (numbers ++ [E.Ident "state", E.Ident "now"]))),
          ("finish", E.Null), ("wait", waitDoc (limitWait l))])
      bulkhead <- forM (policyBulkhead policy) $ \b -> do
        start <- evaluator (bulkheadStart b)
        admit <- evaluator (bulkheadAdmit b)
        release <- evaluator (bulkheadRelease b)
        let n = [big (bulkheadLimit b)]
        pure (object [("kind", E.Str "bulkhead"), ("start", E.arrow [anyParam "now"] (callTo start (n ++ [E.Ident "now"]))),
          ("admit", E.arrow (map anyParam ["state", "now"]) (callTo admit (n ++ [E.Ident "state", E.Ident "now"]))),
          ("finish", E.arrow (map anyParam ["state", "now", "succeeded"]) (callTo release [E.Ident "state"])), ("wait", waitDoc (bulkheadWait b))])
      pure (maybe [] pure breaker ++ maybe [] pure limit ++ maybe [] pure bulkhead)
    waitDoc wait = case wait of
      Nothing -> E.Null
      Just Nothing -> E.Unary "-" (E.BigIntLit "1")
      Just (Just d) -> big d
    object fields = E.Object [E.Prop (E.KName k) v | (k, v) <- fields]
    big n = if n < 0 then E.Unary "-" (E.BigIntLit (show (negate n))) else E.BigIntLit (show n)
    jitterName j = case j of
      NoJitter -> "none"
      FullJitter -> "full"
      EqualJitter -> "equal"
      DecorrelatedJitter -> "decorrelated"
    nativeUnit unit = do
      functions <- mapM native (unitDefinitions unit)
      let unitName = idText (unitId unit)
          depth = 1 + length (filter (== '.') unitName)
          root = concat (replicate depth "../")
          path = "src/lawspec_definitions/" ++ map (\c -> if c == '.' then '/' else c) unitName ++ "." ++ extension
      pure (file False path root [("_definitions", E.ImportDecl False (E.ImportNamespace "_definitions") (root ++ "lawspec_definition_bodies." ++ importExtension ts))] functions)
    native d = do
      let root = concat (replicate (1 + length (filter (== '.') (idText (unitId (ownerOf d))))) "../")
      let declaration = definitionDeclaration d
          (args,result) = functionType (declarationType declaration)
          values = argumentNames d
          -- The dynamic value of each native argument.
          dynamicNames = fst (claimAll (scopeWith (X.webReserved ++ values ++ ["result"])) [v ++ "Value" | v <- values])
      types <- mapM (Native.webDataTypeOf declarations) args
      resultType <- Native.webDataTypeOf declarations result
      arguments <- sequence [schemaCall "fromNative" ty (E.Ident value) | (ty,value) <- zip args values]
      name <- maybe (Left "unresolved JS/TS native call") Right (lookup (declarationId declaration) callees)
      output <- schemaCall "toNative" result (E.Ident "result")
      let handlers = [ (ability, lowerFirst (interfaceName a), a) | ability <- declarationUses declaration, not (isFail ability)
                     , Just (_, a) <- [findAbility units ability] ]
          parameters = symbols : [annotated handlerName (E.TRaw ("import(" ++ E.javascriptLiteral (root ++ "lawspec_abilities/" ++
              map (\c -> if c == '.' then '/' else c) (ownerName a) ++ ".js") ++ ")." ++ interfaceName a)) | (_, handlerName, a) <- handlers] ++
            [annotated value ty | (value,ty) <- zip values types]
          -- Native code passes a definition's handlers explicitly; they are
          -- installed in symbols, where the operations it performs find them.
          installs = [E.ExprStmt (E.call "ls.installHandlers" [E.Ident "symbols", E.Object
            [E.Prop (E.KString (abilityKey ability)) (E.Ident handlerName) | (ability, handlerName, _) <- handlers]]) | not (null handlers)]
          inputs = installs ++ [E.constDecl dynamic value | (dynamic,value) <- zip dynamicNames arguments]
          waiting = "await " `isPrefixOf` name
          invocation = (if waiting then E.Await else id)
            (E.call (plainCall name) (E.Ident "symbols" : map E.Ident dynamicNames))
      pure (linked d (E.FunctionDecl True waiting (declarationName declaration) [] parameters
        (annotation (if waiting then E.TRef "Promise" [resultType] else resultType))
        [contextual (declarationId declaration) (inputs ++ [E.constDecl "result" invocation, E.ret output])]))
    ownerOf d = case [u | u <- units, d `elem` unitDefinitions u] of
      u : _ -> u
      [] -> error "a definition without a unit"
    lowerFirst (c:cs) = toLower c : cs
    lowerFirst [] = []
