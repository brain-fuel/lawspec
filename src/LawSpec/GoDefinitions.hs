-- | Go native entry points and checked bodies live in each unit's source package.
module LawSpec.GoDefinitions (emitGoDefinitions, emitGoDefinitionsWithCalls, definitionCalls) where

import LawSpec.Core.Stages (stageFailures)
import Control.Monad (forM)
import LawSpec.Core.Policy
import LawSpec.Core
import LawSpec.Core.DefinitionContracts (checkedDefinitionContracts)
import LawSpec.Core.Evidence (runtimePostconditions)
import LawSpec.Common (Artifact(..))
import qualified LawSpec.GoData as Native
import qualified LawSpec.GoExpr as E
import qualified LawSpec.Code.Doc as D
import LawSpec.RuntimeSources (runtimeSource)
import LawSpec.Typed.Go (GoTyped(..), emitGoTyped)
import LawSpec.Typed.Plan (TypedPlan(..), sharedDefinitions)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Foldable (toList)
import LawSpec.Typed.Plan (isTypedHandler, isContextual)
import Data.Char (toUpper)
import Data.List (nub, intercalate)
import LawSpec.AbilityNames (interfaceName, specName)

-- | Generated tests call checked definitions by these names, so every test
-- file agrees.
definitionCalls :: [Unit] -> [(Id,String)]
definitionCalls units = [(declarationId (definitionDeclaration d), "lawSpecEvaluate" ++ show i)
  | (i,d) <- zip [0::Int ..] (concatMap unitDefinitions units)]

-- | Checked definitions are emitted as ordinary Go code, so adapters and tests call
-- the same proved implementation. ref:DEC-total-definitions
emitGoDefinitions :: D.Layout -> Int -> [DataDeclaration] -> [Unit] -> Either String [Artifact]
emitGoDefinitions = emitGoDefinitionsWithCalls []

-- | With native bindings, an orchestration calls each bound adapter's bridge
-- (bound), which takes every argument natively, Units too.
emitGoDefinitionsWithCalls :: [(Id,String)] -> D.Layout -> Int -> [DataDeclaration] -> [Unit] -> Either String [Artifact]
emitGoDefinitionsWithCalls _ _ _ _ units | null (concatMap unitDefinitions units) = pure []
emitGoDefinitionsWithCalls bound layout bits declarations units = do
  contracts <- checkedDefinitionContracts bits declarations units
  typed <- emitGoTyped declarations units
  -- Definitions that are the same up to their names (an import's copies)
  -- share one body; the others call it.
  -- Each package holds its own bodies, so only copies within one unit share.
  let unitOf = M.fromList [(declarationId (definitionDeclaration d), unitId u) | u <- units, d <- unitDefinitions u]
      shared = M.filterWithKey (\i target -> M.lookup i unitOf == M.lookup target unitOf) (sharedDefinitions units)
      everyIndex = M.fromList [(declarationId (definitionDeclaration d), i) | (i, d) <- zip [0::Int ..] (concatMap unitDefinitions units)]
      delegate i d target = pure (line ("func lawSpecEvaluate" ++ show i) <>
        D.delimitTrailing 8 "(" ")" (symbols : [line ("value" ++ show k ++ " LawSpecValue") | k <- [0 .. length (definitionArguments d) - 1]]) <>
        line " LawSpecValue " <> D.block 8 (line ("return lawSpecEvaluate" ++ show target ++ "(" ++ intercalate ", " ("symbols" : ["value" ++ show k | k <- [0 .. length (definitionArguments d) - 1]]) ++ ")")))
  bodies <- mapM (\(i, (owner, d)) -> (,) (owner, definitionOrchestrates d, declarationId (definitionDeclaration d)) <$>
      case M.lookup (declarationId (definitionDeclaration d)) shared >>= (`M.lookup` everyIndex) of
        Just target -> delegate i d target
        Nothing -> maybe (implementation contracts (i, d)) (bridge typed i d) (goTypedFunction typed (declarationId (definitionDeclaration d))))
    (zip [0::Int ..] [(unitId u, d) | u <- units, d <- unitDefinitions u])
  let plan = goTypedPlan typed
      hasTyped = not (M.null (typedDefinitions plan))
      everyDefinition = M.fromList [(declarationId (definitionDeclaration d), d) | u <- units, d <- unitDefinitions u]
      -- The handlers each package declares: its own, and every handler a
      -- body installs (LawSpec.AbilityEmit.Go).
      scoped = [h | v <- units, d <- unitDefinitions v, h <- scopedHandlers (definitionBody d)]
      handlersOf u = unitHandlers u ++ [h | identity <- scoped, v <- units, h <- unitHandlers v, handlerId h == identity]
      -- A package's bodies: its unit's definitions, its handlers' clauses,
      -- and everything they reach.
      reachable u = closure S.empty (map (declarationId . definitionDeclaration) (unitDefinitions u) ++
        [clause | h <- handlersOf u, (_, clause) <- handlerClauses h] ++
        concatMap calledIn (concatMap propertyExpressions (unitProperties u) ++
          concatMap (\c -> contractExpressions c ++ contractRuntimePostconditions c) (unitContracts u) ++
          concatMap (harnessExpressions . propertyHarness) (unitProperties u) ++
          maybe [] (map snd . harnessBenchmarks) (unitHarnessSettings u)))
      harnessExpressions h = map coverWhen (harnessCover h) ++ map fst (harnessClassify h) ++
        harnessLabels h ++ maybe [] pure (harnessTarget h)
      closure seen [] = seen
      closure seen (i : rest)
        | i `S.member` seen = closure seen rest
        | otherwise = closure (S.insert i seen) (maybe [] reaches (M.lookup i everyDefinition) ++ rest)
      reaches d = maybe [] pure (M.lookup (declarationId (definitionDeclaration d)) shared) ++ concatMap calledIn (definitionBody d : map snd (stageFailures d) ++ concatMap (\c -> contractExpressions c ++ contractRuntimePostconditions c) (contractsOf d)) ++
        maybe [] toList (definitionPolicy d) ++
        [clause | h <- concatMap scopedHandlers [definitionBody d], v <- units, x <- unitHandlers v, handlerId x == h, (_, clause) <- handlerClauses x]
      contractsOf d = [c | c <- contracts, contractDeclaration c == declarationId (definitionDeclaration d)]
      calledIn e = case expressionNode e of
        ExternalCall i args -> i : concatMap calledIn args
        _ -> concatMap calledIn (children e)
      typedFiles unit = do
        let identity = idText (unitId unit)
            packageName = reverse (takeWhile (/= '.') (reverse identity))
            directory = map (\c -> if c == '.' then '/' else c) identity
            held = [i | i <- S.toList (reachable unit), M.member i (typedDefinitions plan)]
            handlerTypes = [ t | h <- handlersOf unit, isTypedHandler plan h
                               , ref <- handlerAbilities h, Just (_, a) <- [findAbility units ref]
                               , (_, ty) <- abilityOperations a, let (args, result) = functionType ty, t <- result : args ]
            boundary = nub ([t | i <- held, Just d <- [M.lookup i everyDefinition], let (args, result) = functionType (declarationType (definitionDeclaration d)), t <- result : args] ++ handlerTypes)
        source <- goTypedSource typed performDoc packageName held boundary
        pure [ Artifact (directory ++ "/lawspec_typed.go") source "generated" "source"
             , Artifact (directory ++ "/lawspec_fast.go") (replace "RUNTIME_PACKAGE" packageName (runtimeSource "go-fast")) "generated" "source" ]
  -- A workflow calls its own package's adapters, so only that package has it;
  -- a package holds only the bodies it reaches.
  files <- mapM (\unit -> let held = reachable unit in
    unitFile typed [body | ((owner, orchestrates, identity), body) <- bodies, identity `S.member` held, not orchestrates || owner == unitId unit] unit) units
  typedArtifacts <- if hasTyped then concat <$> mapM typedFiles units else pure []
  pure (files ++ typedArtifacts)
  where
    scopedHandlers e = case expressionNode e of
      Handle (WithHandler _ (SpecHandler h)) body -> h : scopedHandlers body
      _ -> concatMap scopedHandlers (children e)
    -- An operation goes to the handler the law installed in symbols for its
    -- ability (evidence passing), through the codecs; typed code calls it
    -- with its arguments' dynamic values.
    performDoc term values = case expressionNode term of
      Perform op args -> do
        let parameterTypes = map expressionType args
            resultType = expressionType term
        codecs <- mapM (Native.goCodecWithContext "symbols" declarations) parameterTypes
        resultCodec <- Native.goCodecWithContext "symbols" declarations resultType
        let call = E.call (handlerOf (operationAbility op) ++ "." ++ capitalize (operationName op))
              [E.call ("codec" ++ show i ++ ".toNative") [value] | (i, value) <- zip [0::Int ..] values]
            result
              | resultType == Constructor "Unit" [] =
                  line "func() LawSpecValue " <> D.block 8 (call <> D.hardline <> line "return resultCodec.fromNative(LawSpecUnit{})") <> line "()"
              | otherwise = E.call "resultCodec.fromNative" [call]
        let performed = line "func() LawSpecValue " <> D.block 8 (D.joinWith D.hardline
              ([line ("schema := " ++ schema), line ("bits := " ++ show bits), line "_, _ = schema, bits"] ++
               [assign ("codec" ++ show i) (line codec) | (i, codec) <- zip [0::Int ..] codecs] ++
               [assign "resultCodec" (line resultCodec), line "return " <> result])) <> line "()"
        -- An operation that fails with E: a native handler panics with
        -- LawSpecFail and a native E, which becomes the failure.
        case findAbility units (operationAbility op) >>= lookup (operationName op) . abilityFailures . snd of
          Just failing@(AbilityRef _ [failure]) -> do
            failureCodec <- Native.goCodecWithContext "symbols" declarations failure
            failureType <- Native.goDataType declarations failure
            pure (E.call "lsNativeFailures" [E.quoted (abilityKey failing),
              line "func(native any) LawSpecValue " <> D.block 8 (D.joinWith D.hardline
                [line ("schema := " ++ schema), line ("bits := " ++ show bits), line "_, _ = schema, bits",
                 line ("return " ++ failureCodec ++ ".fromNative(native.(" ++ failureType ++ "))")]),
              line "func() LawSpecValue " <> D.block 8 (line "return " <> performed)])
          _ -> pure performed
      _ -> Left "not an operation"
    replace old new text = case text of
      [] -> []
      _ | take (length old) text == old -> new ++ replace old new (drop (length old) text)
      c : rest -> c : replace old new rest
    -- A typed definition's dynamic entry converts its arguments and result.
    bridge typed index d function = do
      let (argTypes, resultType) = functionType (declarationType (definitionDeclaration d))
          arguments = [line ("value" ++ show i ++ " LawSpecValue") | i <- [0 .. length argTypes - 1]]
      froms <- mapM (goTypedFrom typed) argTypes
      to <- goTypedTo typed resultType
      pure (line ("func lawSpecEvaluate" ++ show index) <> D.delimitTrailing 8 "(" ")" (symbols : arguments) <> line " LawSpecValue " <>
        D.block 8 (line ("return " ++ to ++ "(" ++ function ++ "(" ++ intercalate ", " (["symbols" | isContextual (goTypedPlan typed) (declarationId (definitionDeclaration d))] ++ [f ++ "(value" ++ show i ++ ")" | (i, f) <- zip [0 :: Int ..] froms]) ++ "))")))
    callees = definitionCalls units
    definitionIds = map (declarationId . definitionDeclaration) (concatMap unitDefinitions units)
    adapters = [(declarationId d, (idText (unitId u), d)) | u <- units, d <- unitDeclarations u,
      declarationId d `notElem` definitionIds]
    width = D.text (show bits)
    schema = "_lawSpecDefinitionSchema"
    symbols = D.text "symbols map[string]*LawSpecSymbol"
    line = D.text
    assign name value = line (name ++ " := ") <> value
    schemaCall method ty value = do
      reference <- D.text <$> Native.goTypeReference ty
      pure (E.call (schema ++ "." ++ method) [reference,value,width,line "symbols"])
    contextual identity resultType body = line "return " <> E.call "lsNativeContext"
      [E.quoted (idText identity),line ("func() " ++ resultType ++ " ") <> D.block 8 body]
    unitFile typed bodies unit = do
      wrappers <- mapM (native typed) (unitDefinitions unit)
      let identity = idText (unitId unit)
          packageName = reverse (takeWhile (/= '.') (reverse identity))
          source = line "// Generated by LawSpec. Do not edit." <> D.hardline <>
            line ("package " ++ packageName) <> D.hardline <> D.hardline <>
            line ("var " ++ schema ++ " = lawSpecDataSchemaRegistry()") <> D.hardline <> D.hardline <>
            line "type lawSpecDefinitions struct{}" <> D.hardline <> D.hardline <>
            line "var LawSpecDefinitions lawSpecDefinitions" <> D.hardline <> D.hardline <>
            D.joinWith (D.hardline <> D.hardline) (wrappers ++ bodies) <> D.hardline
      pure (Artifact (map (\c -> if c == '.' then '/' else c) identity ++ "/lawspec_definitions.go")
        (D.render (if layout == D.Compact then D.CompactTabs else layout) source) "generated" "source")
    implementation contracts (index,d) = do
      let binders = definitionArguments d ++ nestedBinders (definitionBody d)
          names = zip (nub (map binderId binders)) ["value" ++ show i | i <- [0::Int ..]]
          local identity = maybe (error "unresolved Go local") id (lookup identity names)
          arguments = [line (local (binderId binder) ++ " LawSpecValue") | binder <- definitionArguments d]
          external term values = case expressionNode term of
            ExternalCall identity _ | Just name <- lookup identity callees ->
              pure (E.call name (line "symbols":values))
            -- handle e with h end: e runs with h installed for its ability,
            -- made afresh each time.
            Handle (WithHandler ability (SpecHandler h)) _ | [body] <- values ->
              pure (E.call "lsWithHandlers" [line "symbols",
                line ("map[string]any{" ++ show (abilityKey ability) ++ ": " ++ specConstructor h ++ "}"),
                line "func() LawSpecValue " <> D.block 8 (line "return " <> body)])
            -- raise aborts to the nearest attempt of its Fail ability.
            Perform op [_] | isFail (operationAbility op) ->
              pure (E.call "lsRaiseFailure" (E.quoted (abilityKey (operationAbility op)) : values))
            -- An operation goes to the handler the law installed in symbols
            -- for its ability (evidence passing), through the codecs.
            Perform _ _ -> performDoc term values
            -- prelude.attempt e: Right of e's value, or Left of its failure.
            Handle (CatchFailure ability) _ | [body] <- values, Constructor "Either" [TypeArgument failure, TypeArgument result] <- expressionType term -> do
              let placeholder = Id "lawspec::attempt::value"
                  side tag ty = do
                    made <- E.renderExpression declarations bits schema (\i -> if i == placeholder then "_value" else local i) external
                      (Expr (expressionType term) (Construct (Id tag) [Expr ty (Local placeholder) (GeneratedFrom placeholder)]) (GeneratedFrom placeholder))
                    pure (line "func(_value LawSpecValue) LawSpecValue " <> D.block 8 (line "return " <> made))
              right <- side "Either::Right" result
              left <- side "Either::Left" failure
              pure (E.call "lsAttempt" [E.quoted (abilityKey ability), line "func() LawSpecValue " <> D.block 8 (line "return " <> body), right, left])
            -- An orchestration calls an adapter of its own package natively:
            -- the values cross to native and back through the codecs.
            ExternalCall identity _ | Just (_, adapter) <- lookup identity adapters -> do
              let (parameterTypes, resultType) = functionType (declarationType adapter)
              codecs <- mapM (Native.goCodecWithContext "symbols" declarations) parameterTypes
              resultCodec <- Native.goCodecWithContext "symbols" declarations resultType
              nativeResult <- Native.goDataType declarations resultType
              -- A Unit argument is passed as its logical value, as the
              -- adapter stub declares it.
              let bridge = lookup (declarationId adapter) bound
                  -- An adapter that uses abilities gets their handlers first.
                  call = E.call (maybe (capitalize (declarationName adapter)) id bridge) $
                    [line (handlerOf a) | a <- declarationUses adapter, not (isFail a)] ++
                    [if ty == Constructor "Unit" [] && bridge == Nothing then value else E.call ("codec" ++ show i ++ ".toNative") [value]
                    | (i, (ty, value)) <- zip [0::Int ..] (zip parameterTypes values)]
                  -- Within its stage's timeout and hedge, when it has them.
                  result
                    | declarationAsync adapter = E.call "lsAwaitStep"
                        [ line "symbols"
                        , line ("func() LawSpecTask[" ++ nativeResult ++ "] ") <> D.block 8 (line "return " <> call)
                        , line ("func(native " ++ nativeResult ++ ") LawSpecValue ") <> D.block 8 (line "return resultCodec.fromNative(native)") ]
                    -- A Unit adapter returns nothing natively.
                    | resultType == Constructor "Unit" [] =
                        line "func() LawSpecValue " <> D.block 8 (call <> D.hardline <> line "return resultCodec.fromNative(LawSpecUnit{})") <> line "()"
                    | otherwise = E.call "resultCodec.fromNative" [call]
              -- An adapter that fails with E: native code panics with LawSpecFail.
              failing <- case [a | a@(AbilityRef _ [_]) <- declarationUses adapter, isFail a] of
                ability@(AbilityRef _ [failure]) : _ -> do
                  failureCodec <- Native.goCodecWithContext "symbols" declarations failure
                  failureType <- Native.goDataType declarations failure
                  pure (\inner -> E.call "lsNativeFailures" [E.quoted (abilityKey ability),
                    line "func(native any) LawSpecValue " <> D.block 8 (line ("return " ++ failureCodec ++ ".fromNative(native.(" ++ failureType ++ "))")),
                    line "func() LawSpecValue " <> D.block 8 (line "return " <> inner)])
                _ -> pure id
              pure (line "func() LawSpecValue " <> D.block 8 (D.joinWith D.hardline
                ([line ("schema := " ++ schema), line ("bits := " ++ show bits), line "_ = bits"] ++
                 [assign ("codec" ++ show i) (line codec) | (i, (ty, codec)) <- zip [0::Int ..] (zip parameterTypes codecs), ty /= Constructor "Unit" [] || bridge /= Nothing] ++
                 [assign "resultCodec" (line resultCodec), line "return " <> failing result])) <> line "()")
            _ -> Left "unresolved Go total call"
      rendered <- E.renderExpression declarations bits schema local external (definitionBody d)
      -- A workflow stage with policies runs under the workflow runtime.
      body <- case definitionPolicy d of
        Nothing -> pure rendered
        Just policy | policyFrame policy ->
          pure (E.call "lsRunWorkflow" [line "symbols", line "func() LawSpecValue " <> D.block 8 (line "return " <> rendered)])
        Just policy -> do
          failures <- forM (stageFailures d) $ \(kind, value) ->
            (\rendered' -> line ("case " ++ show kind ++ ": return ") <> rendered') <$>
              E.renderExpression declarations bits schema local external value
          let fail' = line "func(kind string) LawSpecValue " <> D.block 8 (D.joinWith D.hardline
                ([line "switch kind " <> D.block 8 (D.joinWith D.hardline failures) | not (null failures)] ++
                 [line "panic(\"unexpected stage failure: \" + kind)"]))
          config <- policyDoc (idText (declarationId (definitionDeclaration d))) fail' policy
          let key = case definitionArguments d of
                argument : _ -> line (local (binderId argument))
                [] -> line "LawSpecValue{}"
          pure (E.call "lsRunStage" [line "symbols", config,
            line "func() LawSpecValue " <> D.block 8 (line "return " <> rendered), key])
      -- Arguments and results were checked where they were built, decoded
      -- or drawn; the native wrappers check values crossing from adapters.
      let checks = []
          result = line "result"
      let contract = lookup (declarationId (definitionDeclaration d)) [(contractDeclaration c,c) | c <- contracts]
      statements <- case contract of
        Nothing -> pure (checks ++ [assign "result" body,line "return " <> result])
        Just c -> do
          let aliases = zip (map binderId (contractArguments c))
                (map (local . binderId) (definitionArguments d)) ++
                [(binderId (contractResult c),"checkedResult")] ++
                [(binderId b,"contractValue" ++ show i) | (i,b) <- zip [0::Int ..]
                  (concatMap nestedBinders (contractPreconditions c ++ contractPostconditions c ++ contractRuntimePostconditions c))]
              resolve identity = maybe (error "unbound Go definition contract binder") id (lookup identity aliases)
              require stage predicate = do
                expression <- E.renderExpression declarations bits schema resolve external predicate
                pure (E.call "lsRequireContract" [E.call "lsTruth" [expression],E.quoted stage])
          pre <- mapM (require "precondition") (contractPreconditions c)
          -- Proved by the totality audit; see LawSpec.Core.Evidence.
          post <- mapM (require "postcondition") (runtimePostconditions c)
          pure (checks ++ pre ++ [assign "result" body,assign "checkedResult" result] ++
            post ++ [line "return checkedResult"])
      pure (line ("func lawSpecEvaluate" ++ show index) <>
        D.delimitTrailing 8 "(" ")" (symbols:arguments) <> line " LawSpecValue " <>
        D.block 8 (contextual (declarationId (definitionDeclaration d)) "LawSpecValue"
          (D.joinWith D.hardline statements)))
    evaluator identity = maybe (Left "unresolved Go policy definition") Right (lookup identity callees)
    policyDoc key fail' policy = do
      gates <- policyGates policy
      compensate <- case policyCompensate policy of
        Nothing -> pure (line "nil")
        Just undo -> (\name -> line ("func(value LawSpecValue) { _ = " ++ name ++ "(symbols, value) }")) <$> evaluator undo
      retry <- case policyRetry policy of
        Nothing -> pure (line "nil")
        Just r -> do
          let (kind, delay, step, factor, cap) = case retryStrategy r of
                Immediate -> ("immediate", 0, 0, 0, -1)
                Fixed d -> ("fixed", d, 0, 0, -1)
                Linear d s -> ("linear", d, s, 0, -1)
                Exponential d f c -> ("exponential", d, 0, f, maybe (-1) id c)
                Fibonacci d -> ("fibonacci", d, 0, 0, -1)
                Custom _ -> ("custom", 0, 0, 0, -1)
          condition <- case retryWhen r of
            Nothing -> pure (line "nil")
            Just p -> (\name -> line ("func(failure LawSpecValue) bool { return lsTruth(" ++ name ++ "(symbols, failure)) }")) <$> evaluator p
          decide <- case retryStrategy r of
            Custom f -> (\name -> line ("func(attempt int64, failure LawSpecValue, previous int64) (int64, bool) { return lsRetryDecision(" ++
              name ++ "(symbols, lsInteger64(attempt), failure, lsDuration(previous))) }")) <$> evaluator f
            _ -> pure (line "nil")
          pure (line "&lawSpecRetry" <> D.block 8 (D.joinWith D.hardline
            [ line ("Strategy: " ++ show (kind :: String) ++ ",")
            , line ("Delay: " ++ show (delay :: Integer) ++ ", Step: " ++ show (step :: Integer) ++ ", Factor: " ++ show (factor :: Integer) ++ ", Cap: " ++ show (cap :: Integer) ++ ",")
            , line ("Attempts: " ++ show (retryAttempts r) ++ ",")
            , line ("Jitter: " ++ show (jitterName (retryJitter r)) ++ ",")
            , line "When: " <> condition <> line ","
            , line "Decide: " <> decide <> line "," ]))
      pure (line "lawSpecStagePolicy" <> D.block 8 (D.joinWith D.hardline
        [ line ("Stage: " ++ show (policyStage policy) ++ ",")
        , line "Retry: " <> retry <> line ","
        , line ("Timeout: " ++ show (maybe (-1) id (policyTimeout policy)) ++ ",")
        , line ("Key: " ++ show key ++ ",")
        , line "Gates: []lawSpecGate" <> D.block 8 (D.joinWith D.hardline [gate <> line "," | gate <- gates]) <> line ","
        , line ("Cache: " ++ show (maybe (-1) id (policyCache policy)) ++ ",")
        , line ("Wraps: " ++ (if null (policyFailures policy) then "false" else "true") ++ ",")
        , line "Fail: " <> fail' <> line ","
        , line "Compensate: " <> compensate <> line ","
        , line ("Hedge: " ++ maybe "nil" (\h -> "&lawSpecHedge{Delay: " ++ show (hedgeDelay h) ++ ", Most: " ++ show (hedgeMost h) ++ "}") (policyHedge policy) ++ ",") ]))
    -- A gate's callbacks call the unit's copies of the resilience unit's
    -- state machines, with the policy's numbers.
    policyGates policy = do
      breaker <- forM (policyBreaker policy) $ \b -> do
        start <- evaluator (breakerStart b)
        admit <- evaluator (breakerAdmit b)
        record <- evaluator (breakerRecord b)
        pure (gateDoc "breaker" (start ++ "(symbols, lsInteger64(now))") (admit ++ "(symbols, state, lsInteger64(now))")
          (Just (record ++ "(symbols, " ++ integers [breakerFailures b, breakerWindow b, breakerCooldown b] ++ ", state, lsInteger64(now), lsBool(succeeded))")) (-2))
      limit <- forM (policyLimit policy) $ \l -> do
        start <- evaluator (limitStart l)
        admit <- evaluator (limitAdmit l)
        let numbers = integers [limitCount l, limitPeriod l]
        pure (gateDoc "limit" (start ++ "(symbols, " ++ numbers ++ ", lsInteger64(now))") (admit ++ "(symbols, " ++ numbers ++ ", state, lsInteger64(now))")
          Nothing (waitCode (limitWait l)))
      bulkhead <- forM (policyBulkhead policy) $ \b -> do
        start <- evaluator (bulkheadStart b)
        admit <- evaluator (bulkheadAdmit b)
        release <- evaluator (bulkheadRelease b)
        let n = integers [bulkheadLimit b]
        pure (gateDoc "bulkhead" (start ++ "(symbols, " ++ n ++ ", lsInteger64(now))") (admit ++ "(symbols, " ++ n ++ ", state, lsInteger64(now))")
          (Just (release ++ "(symbols, state)")) (waitCode (bulkheadWait b)))
      pure (maybe [] pure breaker ++ maybe [] pure limit ++ maybe [] pure bulkhead)
    gateDoc kind start admit finish wait = line "lawSpecGate" <> D.block 8 (D.joinWith D.hardline
      [ line ("Kind: " ++ show (kind :: String) ++ ",")
      , line ("Start: func(now int64) LawSpecValue { return " ++ start ++ " },")
      , line ("Admit: func(state LawSpecValue, now int64) LawSpecValue { return " ++ admit ++ " },")
      , line ("Finish: " ++ maybe "nil" (\f -> "func(state LawSpecValue, now int64, succeeded bool) LawSpecValue { return " ++ f ++ " }") finish ++ ",")
      , line ("Wait: " ++ show (wait :: Integer) ++ ",") ])
    integers numbers = intercalate ", " ["lsInteger64(" ++ show n ++ ")" | n <- numbers]
    waitCode wait = case wait of
      Nothing -> -2
      Just Nothing -> -1
      Just (Just d) -> d
    jitterName j = case j of
      NoJitter -> "none" :: String
      FullJitter -> "full"
      EqualJitter -> "equal"
      DecorrelatedJitter -> "decorrelated"
    -- A typed definition whose types all convert directly calls its typed
    -- function between the conversions.
    native typed d
      | Just function <- goTypedFunction typed (declarationId (definitionDeclaration d))
      , not (isContextual (goTypedPlan typed) (declarationId (definitionDeclaration d)))
      , let (args, result) = functionType (declarationType (definitionDeclaration d))
      , Just conversions <- mapM (goTypedNative typed) args
      , Just (_, toNative) <- goTypedNative typed result = do
          types <- mapM (Native.goDataType declarations) args
          resultType <- Native.goDataType declarations result
          let declaration = definitionDeclaration d
              parameters = symbols : [line ("value" ++ show i ++ " " ++ ty) | (i, ty) <- zip [0 :: Int ..] types]
          pure (line ("func (lawSpecDefinitions) " ++ capitalize (declarationName declaration)) <>
            D.delimitTrailing 8 "(" ")" parameters <> line (" " ++ resultType ++ " ") <>
            D.block 8 (line ("return " ++ toNative ++ "(" ++ function ++ "(" ++
              intercalate ", " ([fromNative ++ "(value" ++ show i ++ ")" | (i, (fromNative, _)) <- zip [0 :: Int ..] conversions]) ++ "))")))
      | otherwise = nativeDynamic d
    nativeDynamic d = do
      let declaration = definitionDeclaration d
          (args,result) = functionType (declarationType declaration)
          values = ["value" ++ show i | i <- [0 .. length args - 1]]
      types <- mapM (Native.goDataType declarations) args
      resultType <- Native.goDataType declarations result
      codecs <- mapM (Native.goCodecWithContext "symbols" declarations) args
      resultCodec <- Native.goCodecWithContext "symbols" declarations result
      name <- maybe (Left "unresolved Go native call") Right (lookup (declarationId declaration) callees)
      let handlers = [ (ability, lowerFirst (interfaceName a), a) | ability <- declarationUses declaration, not (isFail ability)
                     , Just (_, a) <- [findAbility units ability] ]
          parameters = symbols : [line (name ++ " " ++ interfaceName a) | (_, name, a) <- handlers] ++ [line (value ++ " " ++ ty) | (value,ty) <- zip values types]
          -- Native code passes a definition's handlers explicitly; they are
          -- installed in symbols, where the operations it performs find them.
          installs = [line ("lsInstallHandlers(symbols, map[string]any{" ++ intercalate ", " [show (abilityKey ability) ++ ": " ++ name | (ability, name, _) <- handlers] ++ "})")
                     | not (null handlers)]
          inputs = installs ++ concat [[assign ("codec" ++ show i) (line codec),
            assign ("argument" ++ show i) (E.call ("codec" ++ show i ++ ".fromNative") [line value])]
            | (i,(value,codec)) <- zip [0::Int ..] (zip values codecs)]
          invocation = E.call name (line "symbols" : [line ("argument" ++ show i) | i <- [0 .. length args - 1]])
      pure (line ("func (lawSpecDefinitions) " ++ capitalize (declarationName declaration)) <>
        D.delimitTrailing 8 "(" ")" parameters <> line (" " ++ resultType ++ " ") <>
        D.block 8 (contextual (declarationId declaration) resultType (D.joinWith D.hardline
          ([line ("schema := " ++ schema),line ("bits := " ++ show bits)] ++ inputs ++
           [assign "resultCodec" (line resultCodec),assign "result" invocation,
            line "return " <> E.call "resultCodec.toNative" [line "result"]]))))
    nestedBinders expression = case expressionNode expression of
      AllElements value binder predicate -> nestedBinders value ++ [binder] ++ nestedBinders predicate
      Let binder value body -> nestedBinders value ++ [binder] ++ nestedBinders body
      AllPayloads value predicates -> nestedBinders value ++ concat
        [binder : nestedBinders predicate | (binder,predicate) <- predicates]
      Match value cases -> nestedBinders value ++ concat
        [caseBinders branch ++ nestedBinders (caseBody branch) | branch <- cases]
      _ -> concatMap nestedBinders (children expression)
    capitalize [] = []
    capitalize (c:cs) = toUpper c:cs
    lowerFirst (c:cs) = toEnum (fromEnum c + (if c >= 'A' && c <= 'Z' then 32 else 0)) : cs
    lowerFirst [] = []
    -- A handler from symbols, as its ability's interface.
    handlerOf ability = "lsHandler(symbols, " ++ show (abilityKey ability) ++ ").(" ++
      maybe "any" (interfaceName . snd) (findAbility units ability) ++ ")"
    -- A spec handler, made with the constructor its package declares.
    specConstructor h = case [x | u <- units, x <- unitHandlers u, handlerId x == h] of
      x : _ -> "New" ++ specName x ++ "(symbols)"
      [] -> "nil"
