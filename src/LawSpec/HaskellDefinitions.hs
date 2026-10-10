-- | Native Haskell functions over pure, checked total-definition implementations.
module LawSpec.HaskellDefinitions (emitHaskellDefinitions, emitHaskellDefinitionsWithBindings, definitionCalls, specHandlerCall) where

import Control.Monad (forM)
import LawSpec.Core.Policy
import LawSpec.Core
import LawSpec.Core.DefinitionContracts (checkedDefinitionContracts)
import LawSpec.Core.Evidence (runtimePostconditions)
import LawSpec.Common (Artifact(..))
import qualified LawSpec.HaskellData as Native
import LawSpec.AbilityNames (interfaceName, fieldName)
import LawSpec.Collections (isCollectionsType)
import qualified LawSpec.HaskellExpr as E
import qualified LawSpec.Code.Doc as D
import Data.Char (toUpper)
import Data.List (nub, intercalate)
import qualified Data.Map.Strict as M
import qualified Data.Set as Set
import LawSpec.RuntimeSources (runtimeSource)
import LawSpec.Typed.Haskell (HaskellTyped(..), emitHaskellTyped)
import LawSpec.Typed.Plan (TypedPlan(..), isTypedHandler, isContextual)

-- | Workflows call adapters, so they live in LawSpecWorkflows, apart from the
-- bodies adapters may import.
definitionCalls :: [Unit] -> [(Id,String)]
definitionCalls units = [(declarationId (definitionDeclaration d),
  (if definitionOrchestrates d then "Workflows" else "Definitions") ++ ".evaluate" ++ show i)
  | (i,d) <- zip [0::Int ..] (concatMap unitDefinitions units)]

-- A spec handler's function: they live with the bodies, which call them for
-- handle ... with h end, and which their clauses call.
specHandlerCall :: [Unit] -> Id -> String
specHandlerCall units h = "Definitions.lawspecHandler" ++ show (length (takeWhile ((/= h) . handlerId) (concatMap unitHandlers units)))

-- | Checked definitions are emitted as ordinary Haskell code, so adapters and tests call
-- the same proved implementation. ref:DEC-total-definitions
emitHaskellDefinitions :: D.Layout -> Int -> [DataDeclaration] -> [Unit] -> Either String [Artifact]
emitHaskellDefinitions = emitHaskellDefinitionsWithBindings []

-- | Bound adapters are native bridges, which take the symbol context first.
emitHaskellDefinitionsWithBindings :: [Id] -> D.Layout -> Int -> [DataDeclaration] -> [Unit] -> Either String [Artifact]
emitHaskellDefinitionsWithBindings _ _ _ _ units | null (concatMap unitDefinitions units) = pure []
emitHaskellDefinitionsWithBindings bound layout bits declarations units = do
  contracts <- checkedDefinitionContracts bits declarations units
  typed <- emitHaskellTyped declarations units
  let indexed = zip [0::Int ..] (concatMap unitDefinitions units)
      plan = hsTypedPlan typed
      hasTyped = not (M.null (typedDefinitions plan))
      body x@(index, d) = maybe (implementation contracts "Definitions" x) (bridge typed index d)
        (hsTypedFunction typed (declarationId (definitionDeclaration d)))
  bodies <- (++) <$> mapM body [x | x@(_, d) <- indexed, not (definitionOrchestrates d)]
    <*> mapM (\h -> if isTypedHandler plan h then typedSpec typed h else spec h) (concatMap unitHandlers units)
  workflows <- mapM (implementation contracts "Workflows") [x | x@(_, d) <- indexed, definitionOrchestrates d]
  wrappers <- mapM (nativeUnit False) (filter (any (not . definitionOrchestrates) . unitDefinitions) units)
  workflowWrappers <- mapM (nativeUnit True) (filter (any definitionOrchestrates . unitDefinitions) units)
  let adapterImports = nub ["import qualified " ++ moduleOf owner | (_, (owner, _)) <- adapters]
  let typedImports = if hasTyped then ["import qualified LawSpecTyped as Typed", "import qualified LawSpecFast as LSF", "import qualified Control.Concurrent.MVar as MVar"] else []
      typedFiles = if hasTyped
        then [ Artifact "src/LawSpecTyped.hs" (hsTypedModule typed) "generated" "source"
             , Artifact "src/LawSpecFast.hs" (runtimeSource "haskell-fast") "generated" "source" ]
        else []
  pure (typedFiles ++ file "LawSpecDefinitionBodies" (if null abilityImports && null typedImports then [] else typedImports ++ abilityImports ++ "" : environment) bodies :
    [file "LawSpecWorkflows" ("import qualified LawSpecDefinitionBodies as Definitions" : adapterImports ++ abilityImports ++ "" : environment) workflows
    | not (null workflows)] ++
    wrappers ++ workflowWrappers)
  where
    names = definitionCalls units
    text = D.text
    -- A typed definition's dynamic entry converts its arguments and result.
    bridge typed index d function = do
      let (argTypes, _) = functionType (declarationType (definitionDeclaration d))
          (_, resultType) = functionType (declarationType (definitionDeclaration d))
          identity = declarationId (definitionDeclaration d)
          arguments = ["value" ++ show i | i <- [0 .. length argTypes - 1]]
          name = "evaluate" ++ show index
          call = unwords (("Typed." ++ function) : ["symbols" | isContextual (hsTypedPlan typed) identity] ++
            ["(Typed." ++ hsTypedFrom typed t ++ " " ++ a ++ ")" | (t, a) <- zip argTypes arguments])
      pure (signature name (text "LS.SymbolContext" : replicate (length arguments) (text "LS.Scalar") ++ [text "P.Either P.String LS.Scalar"]) <> D.hardline <>
        text (unwords (name : "symbols" : arguments) ++ " = P.Right (LS.performIO (P.fmap Typed." ++ hsTypedTo typed resultType ++ " (" ++ call ++ ")))"))
    -- A typed spec handler keeps its typed state in an MVar: each operation
    -- converts its arguments, runs the typed clause and keeps the next state,
    -- which shares all it did not change with the state before. Operations
    -- apply one at a time, and a failing one leaves the state as it was.
    typedSpec typed h = do
      answered <- forM (handlerAbilities h) $ \ref -> do
        (_, ability) <- maybe (Left ("unknown ability of handler " ++ handlerName h)) Right (findAbility units ref)
        pure (ref, ability)
      let name = drop (length ("Definitions." :: String)) (specHandlerCall units (handlerId h))
          recordOf (ref, ability) = typesModuleOf ref ++ "." ++ interfaceName ability
          qualifierOf (ref, _) = typesModuleOf ref ++ "."
          plan = hsTypedPlan typed
          stateful = handlerState h /= Nothing
      stateType <- case handlerState h of
        Just (t, _) -> hsTypedType typed t
        Nothing -> pure "()"
      start <- case handlerState h of
        Nothing -> pure [text "state <- MVar.newMVar ()"]
        Just _ -> do
          made <- maybe (Left ("untyped start of " ++ handlerName h)) Right (hsTypedStart typed (handlerId h))
          pure [text ("start <- Typed." ++ made ++ " symbols"), text "state <- MVar.newMVar start"]
      let recordFor answer@(_, ability) = do
            fields <- forM (zip [0 :: Int ..] (abilityOperations ability)) $ \(i, (op, ty)) -> do
              clause <- maybe (Left (handlerName h ++ ": no clause for " ++ op)) Right (lookup op (handlerClauses h))
              function <- maybe (Left ("untyped clause " ++ idText clause)) Right (hsTypedFunction typed clause)
              let (args, result) = functionType ty
                  values = ["value" ++ show k | k <- [0 .. length args - 1]]
                  inputs = [text ("let !argument" ++ show k ++ " = Typed." ++ hsTypedFromNative typed t ++ " " ++ v) | (k, (t, v)) <- zip [0 :: Int ..] (zip args values)]
                  arguments = ["symbols" | isContextual plan clause] ++ ["current" | stateful] ++
                    (if null args && not stateful then ["()"] else ["argument" ++ show k | k <- [0 .. length args - 1]])
                  invocation = unwords (("Typed." ++ function) : arguments)
                  lambda = if null values then mempty else text ("\\" ++ unwords values ++ " -> ")
                  out = text ("P.pure P.$! Typed." ++ hsTypedToNative typed result ++ " result")
                  body = lambda <> text "do" <> D.nest 2 (D.hardline <> D.joinWith D.hardline (inputs ++
                    (if stateful
                      then [ text "result <- MVar.modifyMVar state (\\current -> do" <> D.nest 2 (D.hardline <> D.joinWith D.hardline
                               [ text ("!pair <- " ++ invocation)
                               , text ("case pair of " ++ hsTypedPair typed ++ " r n -> P.pure (n, r))") ]) ]
                      else [text ("!result <- " ++ invocation)]) ++ [out]))
              pure (text ((if i == 0 then "{ " else ", ") ++ qualifierOf answer ++ fieldName ability op ++ " =") <> D.nest 4 (D.hardline <> body))
            pure (text ("P.pure " ++ recordOf answer) <> D.nest 2 (D.hardline <> D.joinWith D.hardline fields <> D.hardline <> text "}"))
      -- The state, read and replaced in its native types.
      access <- case handlerState h of
        Nothing -> pure []
        Just (t, _) -> do
          native <- Native.haskellDataType declarations t
          let parenthesized x = if ' ' `elem` x && take 1 x /= "(" && take 1 x /= "[" then "(" ++ x ++ ")" else x
          pure [ text ("-- | The state of " ++ handlerName h ++ ", in its native types: a snapshot to show or keep.") <> D.hardline <>
                 text (name ++ "Snapshot :: MVar.MVar " ++ stateType ++ " -> P.IO " ++ parenthesized native) <> D.hardline <>
                 text (name ++ "Snapshot state = P.fmap Typed." ++ hsTypedToNative typed t ++ " (MVar.readMVar state)")
               , text ("-- | Replaces the state of " ++ handlerName h ++ ": to force it, reset it or restore a snapshot.") <> D.hardline <>
                 text (name ++ "Restore :: MVar.MVar " ++ stateType ++ " -> " ++ parenthesized native ++ " -> P.IO ()") <> D.hardline <>
                 text (name ++ "Restore state native = let !typed = Typed." ++ hsTypedFromNative typed t ++ " native in MVar.modifyMVar_ state (\\_ -> P.pure typed)") ]
      case answered of
        [answer@(_, ability)] | not stateful -> do
          made <- recordFor answer
          pure (text ("-- | The spec handler " ++ handlerName h ++ " for " ++ abilityName ability ++ ", with its state typed.") <> D.hardline <>
            text (name ++ " :: LS.SymbolContext -> P.IO " ++ recordOf answer) <> D.hardline <>
            text (name ++ " symbols = do") <> D.nest 2 (D.hardline <> D.joinWith D.hardline (start ++ [text "_ <- P.pure state", made])))
        _ -> do
          parts <- forM answered $ \answer@(_, ability) -> do
            made <- recordFor answer
            let part = name ++ abilityName ability
            pure (text ("-- | " ++ handlerName h ++ " as a " ++ abilityName ability ++ " handler, over its typed state.") <> D.hardline <>
              text (part ++ " :: LS.SymbolContext -> MVar.MVar " ++ stateType ++ " -> P.IO " ++ recordOf answer) <> D.hardline <>
              text (part ++ " symbols state = do") <> D.nest 2 (D.hardline <> text "_ <- P.pure state" <> D.hardline <> made))
          let stateDoc = text ("-- | The typed state of the spec handler " ++ handlerName h ++ ", made afresh.") <> D.hardline <>
                text (name ++ "State :: LS.SymbolContext -> P.IO (MVar.MVar " ++ stateType ++ ")") <> D.hardline <>
                text (name ++ "State symbols = do") <> D.nest 2 (D.hardline <> D.joinWith D.hardline (start ++ [text "P.pure state"]))
              (firstRef, firstAbility) = case answered of { a : _ -> a; [] -> error "a handler of no ability" }
              freshDoc = text ("-- | The spec handler " ++ handlerName h ++ " as a " ++ abilityName firstAbility ++ " handler, with its own state.") <> D.hardline <>
                text (name ++ " :: LS.SymbolContext -> P.IO " ++ recordOf (firstRef, firstAbility)) <> D.hardline <>
                text (name ++ " symbols = " ++ name ++ "State symbols P.>>= " ++ name ++ abilityName firstAbility ++ " symbols")
          pure (D.joinWith (D.hardline <> D.hardline) (stateDoc : freshDoc : parts ++ access))
    file name imports bodies = Artifact ("src/" ++ map (\c -> if c == '.' then '/' else c) name ++ ".hs")
      (D.render layout (D.joinWith D.hardline (map text
        (["{-# LANGUAGE BangPatterns #-}", "-- Generated by LawSpec. Do not edit."] ++
         -- Each performed operation must run where it is written, once.
         ["{-# OPTIONS_GHC -fno-cse -fno-full-laziness #-}" | performing] ++
         ["module " ++ name ++ " where", "",
          "import qualified Prelude as P", "import qualified Data.Int as I", "import qualified Data.Word as W",
          "import qualified Data.Text as T", "import qualified Data.ByteString as B", "import qualified Data.Complex as C",
          "import qualified Data.IORef as IORef",
          "import LawSpecRuntime (Scalar(..))", "import qualified LawSpecRuntime as LS",
          "import qualified LawSpecSchema as Schema", "import qualified LawSpecCodecs as Codec",
          "import qualified LawSpecData as Data", "import qualified LawSpecDataSchema as DataSchema",
          "import qualified LawSpecDataCodecs as Codecs"] ++
         concat [["import qualified LawSpecCollectionCodecs as Collections", "import qualified Data.Set as Set",
                  "import qualified Data.Map.Strict as Map", "import qualified Data.Sequence as Seq"]
                 | any (isCollectionsType . idText . dataId) declarations] ++ imports ++
         (if null imports then "" : environment else []) ++ [""])) <>
        D.hardline <> D.joinWith (D.hardline <> D.hardline) bodies <> D.hardline)) "generated" "source"
    environment = ["_lawspecSchema :: Schema.Schema",
      "_lawspecSchema = P.either P.error P.id DataSchema.schema",
      "_lawspecBits :: P.Int", "_lawspecBits = " ++ show bits]
    signature name types = D.group (text (name ++ " ::") <>
      D.nest 2 (D.softline <> D.joinWith (text " ->" <> D.softline) types))
    context identity body = E.apply "Codec.context" [E.quoted (idText identity)] <> text " P.$ do" <>
      D.nest 2 (D.hardline <> D.joinWith D.hardline body)
    binding name arguments body = text (unwords (name : "symbols" : arguments) ++ " =") <>
      D.nest 2 (D.hardline <> body)
    validate ty value = do
      ref <- Native.haskellTypeReferenceDoc ty
      pure (E.apply "Schema.validateWith" [E.apply "P.Just" [text "symbols"],text "_lawspecSchema",ref,text "_lawspecBits",value])
    adapters = [ (callee, (owner, adapter)) | d <- concatMap unitDefinitions units, definitionOrchestrates d
               , callee <- callsIn (definitionBody d), Just (owner, adapter) <- [lookup callee adapterTable] ]
    adapterTable = [(declarationId d, (unitId u, d)) | u <- units, d <- unitDeclarations u,
      declarationId d `notElem` map (declarationId . definitionDeclaration) (concatMap unitDefinitions units)]
    callsIn expression = case expressionNode expression of
      ExternalCall callee arguments -> callee : concatMap callsIn arguments
      _ -> concatMap callsIn (children expression)
    moduleOf owner = intercalate "." (map modulePart (split '.' (idText owner)))
    -- An operation's field in its ability's record, and the handler the
    -- symbol context holds for an ability.
    -- An adapter that fails with E: its native code throws LS.Fail with a
    -- native E.
    failing adapter = failingAs [a | a@(AbilityRef _ [_]) <- declarationUses adapter, isFail a]
    failingAs failures call = case failures of
      ability@(AbilityRef _ [failure]) : _ ->
        let context' = E.apply "P.Just" [text "symbols"]
            codec = either error id (Native.haskellCodecDocWithContext context' declarations "_lawspecSchema" "_lawspecBits" failure)
            native = either error id (Native.haskellDataType declarations failure)
        in E.apply "LS.nativeFailures" [E.quoted (abilityKey ability),
             text "((\\_native -> " <> E.checked (E.apply "Codec.encode" [codec, text "_native"]) <> text (") :: " ++ native ++ " -> LS.Scalar)"),
             text "(\\() -> " <> call <> text ")", text "[]"]
      _ -> call
    abilityOwner ability = fst <$> findAbility units ability
    typesModuleOf ability = maybe "LawSpecAbilities" (\u -> "LawSpecAbilities." ++ moduleOf (unitId u)) (abilityOwner ability)
    -- A spec handler: a record of its ability's operations, each running its
    -- clause (a handler with state keeps it in an IORef).
    spec h = do
      answered <- forM (handlerAbilities h) $ \ref -> do
        (_, ability) <- maybe (Left ("unknown ability of handler " ++ handlerName h)) Right (findAbility units ref)
        pure (ref, ability)
      let name = drop (length ("Definitions." :: String)) (specHandlerCall units (handlerId h))
          context' = E.apply "P.Just" [text "symbols"]
          codec = Native.haskellCodecDocWithContext context' declarations "_lawspecSchema" "_lawspecBits"
          recordOf (ref, ability) = typesModuleOf ref ++ "." ++ interfaceName ability
          qualifierOf (ref, _) = typesModuleOf ref ++ "."
          stateful = handlerState h /= Nothing
      start <- case handlerState h of
        Nothing -> pure []
        -- A computed start value is its own definition (<handler>Start).
        Just (_, Expr _ (ExternalCall startDefinition _) _) -> do
          evaluate <- maybe (Left ("unresolved start of " ++ handlerName h)) Right (lookup startDefinition names)
          pure [text "state <- IORef.newIORef P.=<< LS.runClause" <> D.nest 2 (D.softline <> E.parens (E.apply (drop (length ("Definitions." :: String)) evaluate) [text "symbols", text "(LS.SAbsent \"Unit\")"]))]
        Just (_, value) -> do
          rendered <- E.renderExpression declarations bits "_lawspecSchema" "symbols" (const "_unbound") (\_ _ -> Left "a handler's start value calls nothing") value
          pure [text "state <- IORef.newIORef" <> D.nest 2 (D.softline <> E.parens rendered)]
      -- The record of one ability's operations, each running its clause.
      let recordFor answer@(_, ability) = do
            fields <- forM (zip [0 :: Int ..] (abilityOperations ability)) $ \(i, (op, ty)) -> do
              clause <- maybe (Left (handlerName h ++ ": no clause for " ++ op)) Right (lookup op (handlerClauses h))
              evaluate <- maybe (Left ("unresolved clause " ++ idText clause)) Right (lookup clause names)
              let (args, result) = functionType ty
                  values = ["value" ++ show k | k <- [0 .. length args - 1]]
                  local' = drop (length ("Definitions." :: String)) evaluate
              codecs <- mapM codec args
              resultCodec <- codec result
              let inputs = [text ("argument" ++ show k ++ " <- ") <> E.apply "Codec.encode" [c, text v] | (k, (c, v)) <- zip [0 :: Int ..] (zip codecs values)]
                  arguments = [text "symbols"] ++ [text "current" | stateful] ++
                    (if null args && not stateful then [text "(LS.SAbsent \"Unit\")"] else [text ("argument" ++ show k) | k <- [0 .. length args - 1]])
                  invocation = E.apply local' arguments
                  lambda = if null values then mempty else text ("\\" ++ unwords values ++ " -> ")
                  body = if not stateful
                    then lambda <> text "LS.runClause (do" <> D.nest 2 (D.hardline <> D.joinWith D.hardline
                      (inputs ++ [text "result <- " <> invocation, E.apply "Codec.decode" [resultCodec, text "result"]]) <> text ")")
                    else lambda <> text "do" <> D.nest 2 (D.hardline <> D.joinWith D.hardline
                      [ text "current <- IORef.readIORef state"
                      , text "(result, next) <- LS.runClause (do" <> D.nest 2 (D.hardline <> D.joinWith D.hardline
                          (inputs ++ [text "pair <- " <> invocation, text "P.pure (LS.pairFields pair))"]))
                      , text "IORef.writeIORef state next"
                      , text "LS.runClause " <> E.parens (E.apply "Codec.decode" [resultCodec, text "result"]) ])
              pure (text ((if i == 0 then "{ " else ", ") ++ qualifierOf answer ++ fieldName ability op ++ " =") <> D.nest 4 (D.hardline <> body))
            pure (text ("P.pure " ++ recordOf answer) <> D.nest 2 (D.hardline <> D.joinWith D.hardline fields <> D.hardline <> text "}"))
      case answered of
        [answer@(_, ability)] -> do
          made <- recordFor answer
          pure (text ("-- | The spec handler " ++ handlerName h ++ " for " ++ abilityName ability ++ ".") <> D.hardline <>
            text (name ++ " :: LS.SymbolContext -> P.IO " ++ recordOf answer) <> D.hardline <>
            text (name ++ " symbols = do") <> D.nest 2 (D.hardline <> D.joinWith D.hardline (start ++ [made])))
        _ -> do
          -- A handler of several abilities: its state, made once, and a
          -- record for each ability over it (handlerPart).
          parts <- forM answered $ \answer@(_, ability) -> do
            made <- recordFor answer
            let part = name ++ abilityName ability
            pure (text ("-- | " ++ handlerName h ++ " as a " ++ abilityName ability ++ " handler, over its state.") <> D.hardline <>
              text (part ++ " :: LS.SymbolContext -> IORef.IORef LS.Scalar -> P.IO " ++ recordOf answer) <> D.hardline <>
              text (part ++ " symbols state = do") <> D.nest 2 (D.hardline <> text "_ <- P.pure state" <> D.hardline <> made))
          let stateDoc = text ("-- | The state of the spec handler " ++ handlerName h ++ ", made afresh.") <> D.hardline <>
                text (name ++ "State :: LS.SymbolContext -> P.IO (IORef.IORef LS.Scalar)") <> D.hardline <>
                text (name ++ "State symbols = do") <> D.nest 2 (D.hardline <> D.joinWith D.hardline
                  ((if stateful then start else [text "state <- IORef.newIORef (LS.SAbsent \"Unit\")"]) ++ [text "_ <- P.pure symbols", text "P.pure state"]))
              (firstRef, firstAbility) = case answered of { a : _ -> a; [] -> error "a handler of no ability" }
              freshDoc = text ("-- | The spec handler " ++ handlerName h ++ " as a " ++ abilityName firstAbility ++ " handler, with its own state.") <> D.hardline <>
                text (name ++ " :: LS.SymbolContext -> P.IO " ++ recordOf (firstRef, firstAbility)) <> D.hardline <>
                text (name ++ " symbols = " ++ name ++ "State symbols P.>>= " ++ name ++ abilityName firstAbility ++ " symbols")
          pure (D.joinWith (D.hardline <> D.hardline) (stateDoc : freshDoc : parts))
    operationOf op = typesModuleOf (operationAbility op) ++ "." ++
      maybe (operationName op) (\(_, a) -> fieldName a (operationName op)) (findAbility units (operationAbility op))
    handlerOf ability = E.apply "LS.handlerOf" [text "symbols", E.quoted (abilityKey ability)]
    abilityImports = ["import qualified LawSpecAbilities." ++ moduleOf (unitId u) | u <- units, not (null (unitAbilities u))]
    performing = any (not . null . unitAbilities) units
    evaluator localName identity = maybe (Left "unresolved Haskell policy definition") (Right . localName) (lookup identity names)
    policyDoc localName key policy = do
      gates <- policyGates localName policy
      compensate <- case policyCompensate policy of
        Nothing -> pure (text "P.Nothing")
        Just undo -> (\name -> text ("(P.Just (\\value -> P.either P.error P.id (" ++ name ++ " symbols value)))")) <$> evaluator localName undo
      retry <- case policyRetry policy of
        Nothing -> pure (text "P.Nothing")
        Just r -> do
          let (kind, delay, step, factor, cap) = case retryStrategy r of
                Immediate -> ("immediate", 0, 0, 0, -1)
                Fixed d' -> ("fixed", d', 0, 0, -1)
                Linear d' s' -> ("linear", d', s', 0, -1)
                Exponential d' f c -> ("exponential", d', 0, f, maybe (-1) id c)
                Fibonacci d' -> ("fibonacci", d', 0, 0, -1)
                Custom _ -> ("custom", 0, 0, 0, -1)
              number n = text (if n < 0 then "(" ++ show (n :: Integer) ++ ")" else show n)
          condition <- case retryWhen r of
            Nothing -> pure (text "P.Nothing")
            Just p -> (\name -> text ("(P.Just (\\failure -> LS.truth (P.either P.error P.id (" ++ name ++ " symbols failure))))")) <$> evaluator localName p
          decide <- case retryStrategy r of
            Custom f -> (\name -> text ("(P.Just (\\attempt failure previous -> LS.retryDecision (P.either P.error P.id (" ++ name ++
              " symbols (LS.SInteger \"Integer\" attempt) failure (LS.durationScalar previous)))))")) <$> evaluator localName f
            _ -> pure (text "P.Nothing")
          pure (E.apply "P.Just" [E.apply "LS.Retry" [E.quoted kind, number delay, number step, number factor, number cap,
            number (retryAttempts r), E.quoted (jitterName (retryJitter r)), condition, decide]])
      pure (E.apply "LS.StagePolicy" [E.quoted (policyStage policy), retry, text (maybe "(-1)" show (policyTimeout policy)),
        E.quoted key, text "[" <> D.joinWith (text ", ") gates <> text "]", text (maybe "(-1)" show (policyCache policy)),
        text (if null (policyFailures policy) then "P.False" else "P.True"), compensate,
        text (maybe "P.Nothing" (\h -> "(P.Just (" ++ show (hedgeDelay h) ++ ", " ++ show (hedgeMost h) ++ "))") (policyHedge policy))])
    -- A gate's callbacks call the unit's copies of the resilience unit's
    -- state machines, with the policy's numbers.
    policyGates localName policy = do
      let checked call = "(P.either P.error P.id (" ++ call ++ "))"
          integer n = "(LS.SInteger \"Integer\" " ++ (if n < 0 then "(" ++ show n ++ ")" else show (n :: Integer)) ++ ")"
          integers = unwords . map integer
          now = "(LS.SInteger \"Integer\" now)"
          gate kind start admit finish wait = E.apply "LS.Gate" [E.quoted kind, text ("(\\now -> " ++ checked start ++ ")"),
            text ("(\\state now -> " ++ checked admit ++ ")"),
            text (maybe "P.Nothing" (\f -> "(P.Just (\\state now succeeded -> " ++ checked f ++ "))") finish), text ("(" ++ show (wait :: Integer) ++ ")")]
          waitCode wait = case wait of
            Nothing -> -2
            Just Nothing -> -1
            Just (Just d') -> d'
      breaker <- forM (policyBreaker policy) $ \b -> do
        start <- evaluator localName (breakerStart b)
        admit <- evaluator localName (breakerAdmit b)
        record <- evaluator localName (breakerRecord b)
        pure (gate "breaker" (start ++ " symbols " ++ now) (admit ++ " symbols state " ++ now)
          (Just (record ++ " symbols " ++ integers [breakerFailures b, breakerWindow b, breakerCooldown b] ++ " state " ++ now ++ " (LS.SBool succeeded)")) (-2))
      limit <- forM (policyLimit policy) $ \l -> do
        start <- evaluator localName (limitStart l)
        admit <- evaluator localName (limitAdmit l)
        let numbers = integers [limitCount l, limitPeriod l]
        pure (gate "limit" (start ++ " symbols " ++ numbers ++ " " ++ now) (admit ++ " symbols " ++ numbers ++ " state " ++ now)
          Nothing (waitCode (limitWait l)))
      bulkhead <- forM (policyBulkhead policy) $ \b -> do
        start <- evaluator localName (bulkheadStart b)
        admit <- evaluator localName (bulkheadAdmit b)
        release <- evaluator localName (bulkheadRelease b)
        let n = integers [bulkheadLimit b]
        pure (gate "bulkhead" (start ++ " symbols " ++ n ++ " " ++ now) (admit ++ " symbols " ++ n ++ " state " ++ now)
          (Just (release ++ " symbols state")) (waitCode (bulkheadWait b)))
      pure (maybe [] pure breaker ++ maybe [] pure limit ++ maybe [] pure bulkhead)
    jitterName j = case j of
      NoJitter -> "none" :: String
      FullJitter -> "full"
      EqualJitter -> "equal"
      DecorrelatedJitter -> "decorrelated"
    implementation contracts home (index,d) = do
      let binders = definitionArguments d ++ nestedBinders (definitionBody d)
          locals = zip (nub (map binderId binders)) ["value" ++ show i | i <- [0::Int ..]]
          local identity = maybe (error "unresolved Haskell local") id (lookup identity locals)
          arguments = map (local . binderId) (definitionArguments d)
          name = "evaluate" ++ show index
          -- Calls within the same module are unqualified.
          localName callee = case break (== '.') callee of
            (prefix, '.' : rest) | prefix == home -> rest
            _ -> callee
          external term values = case expressionNode term of
            ExternalCall identity _ | Just callee <- lookup identity names ->
              pure (E.checked (E.apply (localName callee) (text "symbols":values)))
            -- handle e with h end: e runs with h installed for its ability,
            -- made afresh each time.
            Handle (WithHandler ability (SpecHandler h)) _ | [body] <- values ->
              pure (E.apply "LS.withHandlers" [text "symbols",
                text ("(P.sequence [P.fmap (LS.installed " ++ show (abilityKey ability) ++ ") (" ++ localName (specHandlerCall units h) ++ " symbols)])"),
                text "(\\() -> " <> body <> text ")"])
            -- raise aborts to the nearest attempt of its Fail ability.
            Perform op [_] | isFail (operationAbility op) ->
              pure (E.apply "LS.raiseFailure" (E.quoted (abilityKey (operationAbility op)) : values))
            -- An operation goes to the handler installed with the symbol
            -- context for its ability (evidence passing), through the codecs.
            Perform op args -> do
              let context' = E.apply "P.Just" [text "symbols"]
              codecs <- mapM (Native.haskellCodecDocWithContext context' declarations "_lawspecSchema" "_lawspecBits" . expressionType) args
              resultCodec <- Native.haskellCodecDocWithContext context' declarations "_lawspecSchema" "_lawspecBits" (expressionType term)
              let call = E.apply "LS.performIO" [E.apply (operationOf op) (handlerOf (operationAbility op) :
                    [E.checked (E.apply "Codec.decode" [codec, value]) | (codec, value) <- zip codecs values])]
              -- An operation that fails with E: a native handler throws
              -- LS.Fail with a native E, which becomes the failure.
              pure (failingAs (maybe [] pure (findAbility units (operationAbility op) >>= lookup (operationName op) . abilityFailures . snd))
                (E.checked (E.apply "Codec.encode" [resultCodec, call])))
            -- prelude.attempt e: Right of e's value, or Left of its failure.
            Handle (CatchFailure ability) _ | [body] <- values, Constructor "Either" [TypeArgument failure, TypeArgument result] <- expressionType term -> do
              let placeholder = Id "lawspec::attempt::value"
                  side tag ty = do
                    made <- E.renderExpression declarations bits "_lawspecSchema" "symbols" (\i -> if i == placeholder then "_value" else local i) external
                      (Expr (expressionType term) (Construct (Id tag) [Expr ty (Local placeholder) (GeneratedFrom placeholder)]) (GeneratedFrom placeholder))
                    pure (text "(\\_value -> " <> made <> text ")")
              right <- side "Either::Right" result
              left <- side "Either::Left" failure
              pure (E.apply "LS.attempt" [E.quoted (abilityKey ability), body, right, left])
            -- A workflow calls an adapter natively, through the codecs.
            ExternalCall identity _ | Just (owner, adapter) <- lookup identity adapterTable -> do
              let (parameterTypes, resultType) = functionType (declarationType adapter)
                  context' = E.apply "P.Just" [text "symbols"]
              codecs <- mapM (Native.haskellCodecDocWithContext context' declarations "_lawspecSchema" "_lawspecBits") parameterTypes
              resultCodec <- Native.haskellCodecDocWithContext context' declarations "_lawspecSchema" "_lawspecBits" resultType
              -- An adapter that uses abilities gets their handlers first, and
              -- runs in IO.
              let handlers = [handlerOf a | a <- declarationUses adapter, not (isFail a)]
                  plain = E.apply (moduleOf owner ++ "." ++ declarationName adapter)
                    ([text "symbols" | identity `elem` bound] ++ handlers ++
                     [E.checked (E.apply "Codec.decode" [codec, value]) | (codec, value) <- zip codecs values])
                  call = if null handlers || declarationAsync adapter then plain else E.apply "LS.performIO" [plain]
              -- An async step runs within its stage's timeout and hedge,
              -- when it has them.
              pure $ if declarationAsync adapter
                then E.apply "LS.awaitStep" [text "symbols", call,
                  text "(\\_native -> " <> E.checked (E.apply "Codec.encode" [resultCodec, text "_native"]) <> text ")"]
                else failing adapter (E.checked (E.apply "Codec.encode" [resultCodec, call]))
            _ -> Left "unresolved Haskell total call"
      -- Arguments and results were checked where they were built, decoded
      -- or drawn; the native wrappers check values crossing from adapters.
      let checks = []
      rendered <- E.renderExpression declarations bits "_lawspecSchema" "symbols" local external (definitionBody d)
      -- A workflow stage with policies runs under the workflow runtime.
      body <- case definitionPolicy d of
        Nothing -> pure rendered
        Just policy | policyFrame policy -> pure (E.apply "LS.runWorkflow" [text "symbols", text "(\\() -> " <> rendered <> text ")"])
        Just policy -> do
          config <- policyDoc localName (idText (declarationId (definitionDeclaration d))) policy
          let key = case arguments of
                argument : _ -> text argument
                [] -> text "(LS.SAbsent \"Unit\")"
          pure (E.apply "LS.runStage" [text "symbols", config, text "(\\() -> " <> rendered <> text ")", key])
      let result = E.apply "P.pure" [text "result"]
      let evaluate = text "let result =" <> D.nest 6 (D.hardline <> body)
          checkedResult = D.group (E.apply "LS.forceScalar" [text "result"] <> text " `P.seq`" <>
            D.nest 2 (D.softline <> result))
          contract = lookup (declarationId (definitionDeclaration d))
            [(contractDeclaration c,c) | c <- contracts]
      statements <- case contract of
        Nothing -> pure (checks ++ [evaluate,checkedResult])
        Just c -> do
          let aliases = zip (map binderId (contractArguments c))
                (map (local . binderId) (definitionArguments d)) ++
                [(binderId (contractResult c),"checkedResult")] ++
                [(binderId b,"contractValue" ++ show i) | (i,b) <- zip [0::Int ..]
                  (concatMap nestedBinders (contractPreconditions c ++ contractPostconditions c ++ contractRuntimePostconditions c))]
              resolve identity = maybe (error "unbound Haskell definition contract binder") id (lookup identity aliases)
              require stage predicate = do
                expression <- E.renderExpression declarations bits "_lawspecSchema" "symbols" resolve external predicate
                pure (D.group (text "if " <> E.apply "LS.truth" [expression] <>
                  D.nest 2 (D.softline <> text "then P.Right ()" <> D.softline <>
                    text "else " <> E.apply "P.Left" [E.quoted (stage ++ " failed")])) )
          pre <- mapM (require "precondition") (contractPreconditions c)
          -- Proved by the totality audit; see LawSpec.Core.Evidence.
          post <- mapM (require "postcondition") (runtimePostconditions c)
          pure (checks ++ pre ++ [evaluate,
            D.group (text "checkedResult <-" <> D.nest 2 (D.softline <> checkedResult))] ++
            post ++ [text "P.Right checkedResult"])
      pure (signature name (text "LS.SymbolContext" : replicate (length arguments) (text "LS.Scalar") ++
          [text "P.Either P.String LS.Scalar"]) <> D.hardline <>
        binding name arguments (context (declarationId (definitionDeclaration d)) statements))
    nativeUnit workflows unit = do
      methods <- mapM native [d | d <- unitDefinitions unit, definitionOrchestrates d == workflows]
      let name = (if workflows then "LawSpecWorkflows." else "LawSpecDefinitions.") ++
            intercalate "." (map modulePart (split '.' (idText (unitId unit))))
      pure (file name ([if workflows then "import qualified LawSpecWorkflows as Workflows"
        else "import qualified LawSpecDefinitionBodies as Definitions"] ++
        -- The handlers a definition takes are its abilities' owners' records.
        nub ["import qualified LawSpecAbilities." ++ moduleOf (unitId owner) | d <- unitDefinitions unit
            , ability <- declarationUses (definitionDeclaration d), not (isFail ability), Just (owner, _) <- [findAbility units ability]]) methods)
    native d = do
      let declaration = definitionDeclaration d
          (args,result) = functionType (declarationType declaration)
          name = declarationName declaration
          values = ["value" ++ show i | i <- [0 .. length args - 1]]
      types <- mapM (Native.haskellDataType declarations) args
      resultType <- Native.haskellDataType declarations result
      codecs <- mapM (Native.haskellCodecDocWithContext (E.apply "P.Just" [text "symbols"]) declarations "_lawspecSchema" "_lawspecBits") args
      resultCodec <- Native.haskellCodecDocWithContext (E.apply "P.Just" [text "symbols"]) declarations "_lawspecSchema" "_lawspecBits" result
      callee <- maybe (Left "unresolved native Haskell call") Right (lookup (declarationId declaration) names)
      let handlers = [ (ability, lowerFirst (interfaceName a), "LawSpecAbilities." ++ moduleOf (unitId u) ++ "." ++ interfaceName a)
                     | ability <- declarationUses declaration, not (isFail ability)
                     , Just (u, a) <- [findAbility units ability] ]
          -- Native code passes a definition's handlers explicitly; they are
          -- installed with the symbol context, where its operations find them.
          installs = [text "() <- P.Right " <> E.parens (E.apply "LS.performIO" [E.apply "LS.installHandlers" [text "symbols",
            E.array [E.apply "LS.installed" [E.quoted (abilityKey ability), text name] | (ability, name, _) <- handlers]]])
            | not (null handlers)]
          checks = installs ++ [D.group (text ("argument" ++ show i ++ " <-") <>
            D.nest 2 (D.softline <> E.apply "Codec.encode" [codec,text value]))
            | (i,(codec,value)) <- zip [0::Int ..] (zip codecs values)]
          invoke = E.apply callee (text "symbols" : [text ("argument" ++ show i) | i <- [0 .. length args - 1]])
      pure (signature name (text "LS.SymbolContext" : [text iface | (_, _, iface) <- handlers] ++ map text types ++
          [text "P.Either P.String " <> E.parens (text resultType)]) <> D.hardline <>
        binding name ([n | (_, n, _) <- handlers] ++ values) (context (declarationId declaration)
          (checks ++ [D.group (text "result <-" <> D.nest 2 (D.softline <> invoke)),
            E.apply "Codec.decode" [resultCodec,text "result"]])) <>
        D.nest 2 (D.hardline <> text "where" <>
          D.nest 2 (D.hardline <> D.joinWith D.hardline (map text environment))))
    nestedBinders expression = case expressionNode expression of
      AllElements value binder predicate -> nestedBinders value ++ [binder] ++ nestedBinders predicate
      Let binder value body -> nestedBinders value ++ [binder] ++ nestedBinders body
      AllPayloads value predicates -> nestedBinders value ++ concat
        [binder : nestedBinders predicate | (binder,predicate) <- predicates]
      Match value cases -> nestedBinders value ++ concat [caseBinders branch ++ nestedBinders (caseBody branch) | branch <- cases]
      _ -> concatMap nestedBinders (children expression)
    split delimiter value = case break (== delimiter) value of
      (a,[]) -> [a]
      (a,_:rest) -> a : split delimiter rest
    lowerFirst (c:cs) = toEnum (fromEnum c + (if c >= 'A' && c <= 'Z' then 32 else 0)) : cs
    lowerFirst [] = []
    modulePart = concatMap capitalize . split '_'
    capitalize [] = []
    capitalize (c:cs) = toUpper c:cs
