-- | Reusable generated definitions: native public signatures, checked logical
-- implementation bodies, and no dependency on a property-testing framework.
module LawSpec.RustDefinitions (operationBridges, abilityTrait, emitRustDefinitions, definitionNames, workflowAdapterUnits) where

import Data.List (intercalate)
import LawSpec.Core.Policy
import Control.Monad (forM)
import Data.Char (isAlphaNum, isUpper)
import LawSpec.Core
import LawSpec.Core.DefinitionContracts (checkedDefinitionContracts)
import LawSpec.Core.Evidence (runtimePostconditions)
import qualified LawSpec.RustData as Native
import qualified LawSpec.RustAbilityPaths as Abilities
import LawSpec.AbilityNames (interfaceName)
import qualified LawSpec.RustExpr as E
import qualified LawSpec.Code.Doc as D
import LawSpec.Typed.Rust (RustTyped(..), emitRustTyped)
import LawSpec.Typed.Plan (sharedDefinitions, isContextual)
import qualified Data.Map.Strict as M
import LawSpec.Naming (NameKind(..), claimAll, scopeWith, nativeIdentifier, readableDefinitionName)
import qualified LawSpec.RustLayout as L

-- | Package-wide resolved IDs, not display names, select implementation bodies.
-- Each is named after its definition (a specialised copy after its
-- definition and argument types), made unique in declaration order.
definitionNames :: [Unit] -> [(Id,String)]
definitionNames units = zip (map (declarationId . definitionDeclaration) definitions)
  (fst (claimAll (scopeWith ["ls", "typed", "schema"])
    [ nativeIdentifier "rust" FunctionName (readableDefinitionName (declarationName declaration) (fst (functionType (declarationType declaration))))
    | d <- definitions, let declaration = definitionDeclaration d ]))
  where definitions = concatMap unitDefinitions units

-- | The adapters workflows call, numbered for their bridges, with their units.
adapterCallsOf :: [Unit] -> [(Int, (Id, Declaration))]
adapterCallsOf units = zip [0::Int ..] (nubIds
  [ (unitId u, a) | d <- concatMap unitDefinitions units, definitionOrchestrates d
  , callee <- callsIn (definitionBody d), u <- units, a <- unitDeclarations u
  , declarationId a == callee, callee `notElem` definitionIds ])
  where
    definitionIds = map (declarationId . definitionDeclaration) (concatMap unitDefinitions units)
    nubIds = foldr (\x acc -> if any ((== declarationId (snd x)) . declarationId . snd) acc then acc else x : acc) []
    callsIn expression = case expressionNode expression of
      ExternalCall callee arguments -> callee : concatMap callsIn arguments
      _ -> concatMap callsIn (children expression)

-- | The units whose adapter modules the definitions file calls.
workflowAdapterUnits :: [Unit] -> [Id]
workflowAdapterUnits units = foldr (\x acc -> if x `elem` acc then acc else x : acc) []
  [owner | (_, (owner, _)) <- adapterCallsOf units]

-- The bridge of each ability operation (LawSpec.AbilityEmit.Rust), by
-- identity, from the crate root.
operationBridges :: [Unit] -> [(Id, String)]
operationBridges = Abilities.performBridges

-- An ability's trait, from the crate root.
abilityTrait :: [Unit] -> AbilityRef -> String
abilityTrait units ref = case Abilities.traitPath units ref of
  "dyn std::any::Any" -> "std::any::Any"
  path -> path

-- | Checked definitions are emitted as ordinary Rust code, so adapters and tests call
-- the same proved implementation. ref:DEC-total-definitions
emitRustDefinitions :: D.Layout -> Int -> [DataDeclaration] -> [Unit] -> Either String String
emitRustDefinitions layout bits declarations units = do
  contracts <- checkedDefinitionContracts bits declarations units
  typed <- emitRustTyped declarations units
  -- Definitions that are the same up to their names (an import's copies)
  -- share one wrapper and one dynamic entry; the others are aliases of it.
  let shared = sharedDefinitions units
      byId = M.fromList [(declarationId (definitionDeclaration d), (unitId u, d)) | u <- units, d <- unitDefinitions u]
      primary d = M.lookup (declarationId (definitionDeclaration d)) shared >>= (`M.lookup` byId)
  implementations <- mapM (\d -> case primary d of
      Just (_, first) -> do
        name <- nameFor d
        target <- nameFor first
        pure (D.text ("pub use self::" ++ target ++ " as " ++ name ++ ";"))
      Nothing -> maybe (implementation contracts d) (bridgeTo typed d) (rustTypedFunction typed (declarationId (definitionDeclaration d))))
    (concatMap unitDefinitions units)
  bridges <- mapM bridge adapterCalls
  modules <- forM (filter (not . null . unitDefinitions) units) $ \unit -> do
    functions <- mapM (\d -> case primary d of
      Just (owner, first) -> pure (D.text ("pub use super::" ++ ownerModule owner ++ "::" ++ declarationName (definitionDeclaration first) ++
        (if declarationName (definitionDeclaration first) == declarationName (definitionDeclaration d) then "" else " as " ++ declarationName (definitionDeclaration d)) ++ ";"))
      Nothing -> native typed d) (unitDefinitions unit)
    pure (D.text ("pub mod " ++ moduleName unit ++ " ") <> D.block 4
      (D.text "use super::ls;" <> D.hardline <> D.hardline <>
        D.joinWith (D.hardline <> D.hardline) functions))
  pure (D.render layout (D.text "// Generated by LawSpec. Do not edit." <> D.hardline <>
    D.text "use crate::lawspec_runtime as ls;" <> D.hardline <> D.hardline <>
    D.joinWith (D.hardline <> D.hardline) (modules ++ implementations ++ bridges ++ [rustTypedModule typed]) <> D.hardline))
  where
    -- A typed definition's dynamic entry converts its arguments and result.
    bridgeTo typed d function = do
      name <- nameFor d
      let arity = length (definitionArguments d)
          (argTypes, _) = functionType (declarationType (definitionDeclaration d))
          header = "pub fn " ++ name
      if isContextual (rustTypedPlan typed) (declarationId (definitionDeclaration d))
        then do
          -- It takes the context, so its arguments are decoded here.
          types <- mapM (rustTypedType typed) argTypes
          let locals = E.sourceLocals [] (definitionArguments d)
              next = L.try' (L.method (L.method (L.atom "arguments") "next" []) "ok_or" [L.Laid (E.stringLiteral "definition argument count mismatch")])
          pure (L.function header ["ctx: &mut ls::Context", (if null types then "_arguments" else "arguments") ++ ": Vec<ls::Value>"] "ls::Result<ls::Value>"
            (L.stmts ([L.Let "mut arguments" (L.method (L.atom "arguments") "into_iter" []) | not (null types)] ++
               concat [[L.Let "value" next, L.Let l (L.try' (L.call ("<" ++ t ++ " as ls::fast::Dyn>::from_dyn") [L.atom "value"]))] | (l, t) <- zip locals types])
              (Just (L.call "Ok" [L.call "ls::fast::Dyn::to_dyn" [L.prefix "&" (L.try' (L.call function (L.atom "ctx" : map L.atom locals)))]]))))
        else pure (L.function header ["_ctx: &mut ls::Context", "arguments: Vec<ls::Value>"] "ls::Result<ls::Value>"
          (L.expr (L.call ("ls::fast::call" ++ show arity) [L.atom "arguments", L.atom function])))
    -- Workflows call adapters natively, each through a bridge that converts
    -- checked values to native ones and back.
    adapterCalls = adapterCallsOf units
    adapterNames = fst (claimAll (scopeWith (map snd (definitionNames units))) [nativeIdentifier "rust" FunctionName ("call " ++ declarationName a) | (_, (_, a)) <- adapterCalls])
    adapterName i = adapterNames !! i
    names = definitionNames units ++ [(declarationId a, adapterName i) | (i, (_, a)) <- adapterCalls] ++
      -- Each operation's bridge finds the handler installed in the context.
      [(identity, "crate::" ++ path) | (identity, path) <- operationBridges units]
    bridge (i, (owner, a)) = do
      let (args,result) = functionType (declarationType a)
      types <- mapM (Native.rustDataType declarations) args
      resultType <- Native.rustDataType declarations result
      refs <- mapM E.reference args
      let natives = ["native_" ++ show n | n <- [0 .. length args - 1]]
          -- Each argument is checked, then decoded to its native type.
          decode (n, native, ty, ref) =
            [ L.Let "value" (L.try' (L.method (L.atom "schema") "native_value_with_context"
                [L.method (L.atom ("arguments[" ++ show n ++ "]")) "clone" [], L.prefix "&" (L.Laid ref), L.atom (show bits), L.atom "ctx"]))
            , L.Let native (L.try' (L.call ("<" ++ ty ++ " as ls::FromValue>::from_value") [L.atom "value"])) ]
          -- An adapter that uses abilities gets their handlers first.
          uses = [ability | ability <- declarationUses a, not (isFail ability)]
          handlerNames = fst (claimAll (scopeWith (natives ++ E.reservedLocals))
            [nativeIdentifier "rust" ValueName (maybe "handler" (interfaceName . snd) (findAbility units ability)) | ability <- uses])
          handlerBindings = [L.Let (h ++ ": std::sync::Arc<dyn crate::" ++ abilityTrait units ability ++ ">") (L.try' (L.method (L.atom "ctx") "handler" [L.atom (show (abilityKey ability))]))
            | (h, ability) <- zip handlerNames uses]
          adapter = "crate::" ++ ownerModule owner ++ "::" ++ declarationName a
          plainCall = L.call adapter (map (L.atom . ("&*" ++)) handlerNames ++ map L.atom natives)
          -- An adapter that fails with E: its native code calls ls::fail.
          call = case [(ability, failure) | ability@(AbilityRef _ [failure]) <- declarationUses a, isFail ability] of
            (ability, failure) : _ -> L.call ("ls::native_failures::<" ++ either error id (Native.rustDataType declarations failure) ++ ", _>")
              [L.atom (show (abilityKey ability)), L.closure "|native|" (L.call "ls::IntoValue::into_value" [L.atom "native"]), L.closure "||" plainCall,
               L.atom (Abilities.mappedFailures bits Nothing [b | u <- units, unitId u == owner, b <- unitFailureBindings u] failure)]
            [] -> plainCall
          -- An async step runs within its stage's timeout and hedge, when it
          -- has them; each hedged attempt starts from copies of the inputs.
          started = L.call adapter [L.method (L.atom native) "clone" [] | native <- natives]
          (finishing, finished)
            | declarationAsync a = ([], L.call "ls::await_step" [L.atom "ctx", L.closure "||" started,
                L.closure ("|native_result: " ++ resultType ++ "|") (L.call "ls::IntoValue::into_value" [L.atom "native_result"])])
            | otherwise = ([L.Let ("native_result: " ++ resultType) call], L.call "Ok" [L.call "ls::IntoValue::into_value" [L.atom "native_result"]])
          statements' = [L.Let "schema" (L.try' (L.call "crate::lawspec_schema::schema" [])) | not (null args)] ++
            concatMap decode (zip4' [0 :: Int ..] natives types refs) ++ handlerBindings ++ finishing
          body = L.stmts statements' (Just finished)
          zip4' (w : ws) (x : xs) (y : ys) (z : zs) = (w, x, y, z) : zip4' ws xs ys zs
          zip4' _ _ _ _ = []
      pure (L.function ("fn " ++ adapterName i)
        [E.unusedAs "ctx" body ++ ": &mut ls::Context", E.unusedAs "arguments" body ++ ": Vec<ls::Value>"] "ls::Result<ls::Value>" body)
    evaluator identity = maybe (Left "unresolved Rust policy definition") Right (lookup identity names)
    -- A callback: its parameters, result type and the call it makes.
    -- (the field's function type gives its parameters' and result's types)
    callback params _ body = L.closure ("|" ++ intercalate ", " [takeWhile (/= ':') p' | p' <- splitParams params] ++ "|") body
    splitParams ps = case break (== ',') ps of
      (p', ',' : ' ' : rest) -> p' : splitParams rest
      (p', _) -> [p']
    numbers ns = [L.call "ls::Value::Integer" [L.call "ls::BigInt::from" [L.atom (show n ++ "i64")]] | n <- ns]
    nowValue = L.call "ls::Value::Integer" [L.call "ls::BigInt::from" [L.atom "now"]]
    called' name args = L.call name [L.atom "ctx", L.vecOf args]
    policyDoc key policy = do
      gates <- policyGates policy
      compensate <- case policyCompensate policy of
        Nothing -> pure (L.atom "None")
        Just undo -> (\name -> L.call "Some" [callback "ctx: &mut ls::Context, value: ls::Value" "ls::Result<ls::Value>" (called' name [L.atom "value"])]) <$> evaluator undo
      retry <- case policyRetry policy of
        Nothing -> pure (L.atom "None")
        Just r -> do
          let (kind, delay, step, factor, cap) = case retryStrategy r of
                Immediate -> ("immediate", 0, 0, 0, -1)
                Fixed d' -> ("fixed", d', 0, 0, -1)
                Linear d' s' -> ("linear", d', s', 0, -1)
                Exponential d' f c -> ("exponential", d', 0, f, maybe (-1) id c)
                Fibonacci d' -> ("fibonacci", d', 0, 0, -1)
                Custom _ -> ("custom", 0, 0, 0, -1)
          condition <- case retryWhen r of
            Nothing -> pure (L.atom "None")
            Just p' -> (\name -> L.call "Some" [callback "ctx: &mut ls::Context, failure: ls::Value" "ls::Result<bool>"
              (L.method (L.try' (called' name [L.atom "failure"])) "boolean" [])]) <$> evaluator p'
          decide <- case retryStrategy r of
            Custom f -> (\name -> L.call "Some" [callback "ctx: &mut ls::Context, attempt: i64, failure: ls::Value, previous: i64" "ls::Result<Option<i64>>"
              (L.call "ls::retry_decision" [L.try' (called' name [L.call "ls::Value::Integer" [L.call "ls::BigInt::from" [L.atom "attempt"]], L.atom "failure", L.call "ls::duration" [L.atom "previous"]])])]) <$> evaluator f
            _ -> pure (L.atom "None")
          pure (L.call "Some" [L.struct "ls::Retry"
            [ ("strategy", L.atom (show (kind :: String)))
            , ("delay", L.atom (show (delay :: Integer))), ("step", L.atom (show (step :: Integer)))
            , ("factor", L.atom (show (factor :: Integer))), ("cap", L.atom (show (cap :: Integer)))
            , ("attempts", L.atom (show (retryAttempts r)))
            , ("jitter", L.atom (show (jitterName (retryJitter r))))
            , ("when", condition), ("decide", decide) ]])
      pure (L.struct "ls::StagePolicy"
        [ ("stage", L.atom (show (policyStage policy)))
        , ("retry", retry)
        , ("timeout", L.atom (show (maybe (-1) id (policyTimeout policy))))
        , ("key", L.atom (show key))
        , ("gates", L.vecOf gates)
        , ("cache", L.atom (show (maybe (-1) id (policyCache policy))))
        , ("wraps", L.atom (if null (policyFailures policy) then "false" else "true"))
        , ("compensate", compensate)
        , ("hedge", maybe (L.atom "None") (\h -> L.call "Some" [L.Macro "" "(" ")" [L.atom (show (hedgeDelay h)), L.atom (show (hedgeMost h))]]) (policyHedge policy)) ])
    -- A gate's callbacks call the unit's copies of the resilience unit's
    -- state machines, with the policy's numbers.
    policyGates policy = do
      breaker <- forM (policyBreaker policy) $ \b -> do
        start <- evaluator (breakerStart b)
        admit <- evaluator (breakerAdmit b)
        record <- evaluator (breakerRecord b)
        pure (gateDoc "breaker" (called' start [nowValue]) (called' admit [L.atom "state", nowValue])
          (Just (called' record (numbers [breakerFailures b, breakerWindow b, breakerCooldown b] ++ [L.atom "state", nowValue, L.call "ls::Value::Bool" [L.atom "succeeded"]]))) (-2))
      limit <- forM (policyLimit policy) $ \l -> do
        start <- evaluator (limitStart l)
        admit <- evaluator (limitAdmit l)
        let ns = numbers [limitCount l, limitPeriod l]
        pure (gateDoc "limit" (called' start (ns ++ [nowValue])) (called' admit (ns ++ [L.atom "state", nowValue])) Nothing (waitCode (limitWait l)))
      bulkhead <- forM (policyBulkhead policy) $ \b -> do
        start <- evaluator (bulkheadStart b)
        admit <- evaluator (bulkheadAdmit b)
        release <- evaluator (bulkheadRelease b)
        let n = numbers [bulkheadLimit b]
        pure (gateDoc "bulkhead" (called' start (n ++ [nowValue])) (called' admit (n ++ [L.atom "state", nowValue])) (Just (called' release [L.atom "state"])) (waitCode (bulkheadWait b)))
      pure (maybe [] pure breaker ++ maybe [] pure limit ++ maybe [] pure bulkhead)
    gateDoc kind start admit finish wait = L.struct "ls::Gate"
      [ ("kind", L.atom (show (kind :: String)))
      , ("start", callback "ctx: &mut ls::Context, now: i64" "ls::Result<ls::Value>" start)
      , ("admit", callback "ctx: &mut ls::Context, state: ls::Value, now: i64" "ls::Result<ls::Value>" admit)
      , ("finish", maybe (L.atom "None") (\f -> L.call "Some" [callback "ctx: &mut ls::Context, state: ls::Value, now: i64, succeeded: bool" "ls::Result<ls::Value>" f]) finish)
      , ("wait", L.atom (show (wait :: Integer))) ]
    waitCode wait = case wait of
      Nothing -> -2
      Just Nothing -> -1
      Just (Just d') -> d'
    jitterName j = case j of
      NoJitter -> "none" :: String
      FullJitter -> "full"
      EqualJitter -> "equal"
      DecorrelatedJitter -> "decorrelated"
    ownerModule = map (\c -> if isAlphaNum c || c == '_' then c else '_') . idText
    moduleName = map (\c -> if isAlphaNum c || c == '_' then c else '_') . idText . unitId
    nameFor d = maybe (Left "unresolved Rust total definition") Right
      (lookup (declarationId (definitionDeclaration d)) names)
    native typed d = do
      name <- nameFor d
      let declaration = definitionDeclaration d
          (args,result) = functionType (declarationType declaration)
      types <- mapM (Native.rustDataType declarations) args
      resultType <- Native.rustDataType declarations result
      resultRef <- E.reference result
      let valueNames = case definitionArguments d of
            binders | length binders == length args -> E.sourceLocals [] binders
            _ -> ["value" ++ show i | i <- [0 .. length args - 1]]
          values = map L.atom valueNames
          -- A handler's parameter is named for its ability; Async's is r#async.
          handlers = [ (ability, nativeIdentifier "rust" ValueName (interfaceName a)) | ability <- declarationUses declaration, not (isFail ability)
                     , Just (_, a) <- [findAbility units ability] ]
          parameters = "ctx: &mut ls::Context" :
            [name ++ ": std::sync::Arc<dyn crate::" ++ abilityTrait units ability ++ ">" | (ability, name) <- handlers] ++
            [n ++ ": " ++ ty | (n,ty) <- zip valueNames types]
          -- Native code passes a definition's handlers explicitly; they are
          -- installed in the context, where its operations find them.
          installs = [L.Semi (L.method (L.atom "ctx") "install_handlers" [L.vecOf
                       [L.Macro "" "(" ")" [L.method (L.atom (show (abilityKey ability))) "to_string" [], L.call "ls::installed" [L.atom name]] | (ability, name) <- handlers]])
                     | not (null handlers)]
          architecture = [L.Semi (L.try' (L.call "ls::require_architecture" [L.atom (show bits)]))
            | nativeMachine [] (declarationType declaration)]
          typedBody = case rustTypedFunction typed (declarationId declaration) of
            -- A typed definition converts its arguments and result directly
            -- (one that takes the context goes through its dynamic entry,
            -- which installs the handlers first).
            Just _ | isContextual (rustTypedPlan typed) (declarationId declaration) -> Nothing
            Just function
              | all (rustTypedNative typed) (result : args) -> Just (L.call ("ls::fast::direct" ++ show (length args)) (values ++ [L.atom function]))
              | otherwise -> Just (L.call ("ls::fast::native" ++ show (length args)) (values ++ [L.atom function]))
            Nothing -> Nothing
          body = case typedBody of
            Just direct -> L.stmts [] (Just direct)
            Nothing -> L.stmts (architecture ++ installs ++
              [ L.Let "arguments" (L.vecOf [L.call "ls::IntoValue::into_value" [value] | value <- values])
              , L.Let "result" (L.try' (L.call ("super::" ++ name) [L.atom "ctx", L.atom "arguments"]))
              , L.Let "schema" (L.try' (L.call "crate::lawspec_schema::schema" []))
              , L.Let "result" (L.try' (L.method (L.atom "schema") "native_value_with_context" [L.atom "result", L.prefix "&" (L.Laid resultRef), L.atom (show bits), L.atom "ctx"])) ])
              (Just (L.call ("<" ++ resultType ++ " as ls::FromValue>::from_value") [L.atom "result"]))
          -- A parameter the body does not read is marked unused.
          parameters' = [ let (n, rest') = break (== ':') p in E.unusedAs n body ++ rest' | p <- parameters ]
      -- The function keeps its definition's name, which Rust's lint may not
      -- call snake case.
      pure ((if any isUpper (declarationName declaration) then D.text "#[allow(non_snake_case)]" <> D.hardline else mempty) <>
        L.function ("pub fn " ++ declarationName declaration) parameters' ("ls::Result<" ++ resultType ++ ">") body)
    implementation contracts d = do
      name <- nameFor d
      let args = definitionArguments d
          -- Arguments keep their source names; none takes a callee's.
          locals = zip (map binderId args) (E.sourceLocals [(Id "", n) | (_, n) <- names, ':' `notElem` n] args)
      rendered <- E.renderExpressionL declarations bits names locals (definitionBody d)
      let workflowClosure inner = L.closure "|ctx: &mut ls::Context| -> ls::Result<ls::Value>" (L.Block [] (Just (L.call "Ok" [inner])))
      -- A workflow stage with policies runs under the workflow runtime.
      body <- case definitionPolicy d of
        Nothing -> pure rendered
        Just policy | policyFrame policy ->
          pure (L.try' (L.call "ls::run_workflow" [L.atom "ctx", workflowClosure rendered]))
        Just policy -> do
          config <- policyDoc (idText (declarationId (definitionDeclaration d))) policy
          let key = case locals of
                (_, local) : _ -> L.method (L.atom local) "clone" []
                [] -> L.atom "ls::Value::Unit"
          pure (L.try' (L.call "ls::run_stage" [L.atom "ctx", L.prefix "&" config, workflowClosure rendered, key]))
      let identity = idText (declarationId (definitionDeclaration d))
          failWith message = L.Block [L.Semi (L.Return (Just (L.call "Err" [L.method (L.atom (E.quoted message)) "into" []])))] Nothing
          arity = L.Do (L.If (L.infixOp "!=" (L.method (L.atom "arguments") "len" []) (L.atom (show (length args))))
            (failWith (identity ++ ": definition argument count mismatch")) Nothing)
          evaluate = L.Let "result" body
          contract = lookup (declarationId (definitionDeclaration d)) [(contractDeclaration c,c) | c <- contracts]
          -- The schema is fetched when the body reads it.
          prefix rest = [arity] ++
            [L.Let "schema" (L.try' (L.call "crate::lawspec_schema::schema" [])) | E.mentions "schema" (L.expr (L.Block rest Nothing))] ++
            [L.Let "mut arguments" (L.method (L.atom "arguments") "into_iter" []) | not (null args)] ++
            [L.Let (E.unusedAs local (L.expr (L.Block rest Nothing))) (L.method (L.method (L.atom "arguments") "next" []) "unwrap" []) | (_, local) <- locals] ++ rest
      statements' <- case contract of
        Nothing -> pure (L.stmts (prefix [evaluate]) (Just (L.call "Ok::<ls::Value, String>" [L.atom "result"])))
        Just c -> do
          let aliases = zip (map binderId (contractArguments c)) (map snd locals) ++
                [(binderId (contractResult c),"checked")]
              require stage predicate = do
                expression <- E.renderExpressionL declarations bits names aliases predicate
                pure [ L.Let "predicate" expression
                     , L.Do (L.If (L.prefix "!" (L.try' (L.method (L.atom "predicate") "boolean" []))) (failWith (stage ++ " failed")) Nothing) ]
          pre <- concat <$> mapM (require "precondition") (contractPreconditions c)
          -- Proved by the totality audit; see LawSpec.Core.Evidence.
          post <- concat <$> mapM (require "postcondition") (runtimePostconditions c)
          let inner = L.Block (prefix (pre ++ [evaluate, L.Let "checked" (L.try' (L.call "Ok::<ls::Value, String>" [L.atom "result"]))] ++ post))
                (Just (L.call "Ok" [L.atom "checked"]))
          pure (L.stmts [ L.Let "result" (L.Call (L.Paren (L.closure "||" inner)) [])
                        , L.Let "context" (L.atom (E.quoted identity)) ]
            (Just (L.method (L.atom "result") "map_err" [L.closure "|error: String|" (L.macroCall "format" [L.atom "\"{context}: {error}\""])])))
      pure (L.function ("pub fn " ++ name)
        [E.unusedAs "ctx" statements' ++ ": &mut ls::Context", "arguments: Vec<ls::Value>"] "ls::Result<ls::Value>" statements')
    -- Inspect every variant, including unselected native machine fields.
    nativeMachine seen ty = case ty of
      Constructor name args -> name `elem` ["IntSize","UIntSize","UIntPtr"] ||
        any (\a -> case a of TypeArgument t -> nativeMachine seen t; _ -> False) args ||
        (name `notElem` seen && any (any (any (nativeMachine (name:seen) . binderType) . constructorFields) . dataConstructors)
          (filter ((== Id name) . dataId) declarations))
      Arrow a b -> nativeMachine seen a || nativeMachine seen b
      _ -> False

