-- | Native Haskell functions over pure, checked total-definition implementations.
--
-- Each definition's function is named after it (LawSpec.Naming), its
-- arguments after the source's, and it is linked to its source line. The
-- modules are laid out as ormolu lays them out (LawSpec.Code.Haskell).
-- ref:DEC-readable-output-default
module LawSpec.HaskellDefinitions (emitHaskellDefinitions, emitHaskellDefinitionsWithBindings, definitionCalls, specHandlerCall, moduleImports, sortedImports) where

import Control.Monad (forM)
import LawSpec.Core.Policy
import LawSpec.Core
import LawSpec.Core.DefinitionContracts (checkedDefinitionContracts)
import LawSpec.Core.Evidence (runtimePostconditions)
import LawSpec.Common (Artifact(..))
import qualified LawSpec.HaskellData as Native
import LawSpec.HaskellData (moduleImports, sortedImports)
import LawSpec.AbilityNames (interfaceName, fieldName)
import LawSpec.Collections (isCollectionsType)
import qualified LawSpec.HaskellExpr as E
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.Code.Haskell as H
import LawSpec.Code.Haskell (Stmt(Bind, Run), call, var, string, integer, lambda, operator)
import LawSpec.Naming (claimAll, scopeWith, nativeIdentifier, NameKind(..), readableDefinitionName)
import LawSpec.SourceLink (labelled, sourceLink, generatedHeader, unitSourceFile)
import LawSpec.TargetNames (targetKeywords)
import Data.Char (isAlphaNum, toUpper)
import Data.List (nub, intercalate)
import Data.Maybe (listToMaybe, mapMaybe)
import qualified Data.Map.Strict as M
import LawSpec.RuntimeSources (runtimeSource)
import LawSpec.Typed.Haskell (HaskellTyped(..), emitHaskellTyped)
import LawSpec.Typed.Plan (TypedPlan(..), isTypedHandler, isContextual)

-- | The names the bodies' modules use besides their functions, which a
-- function or a local must not take.
moduleNames :: [String]
moduleNames = targetKeywords "haskell" ++ words
  "schema machineBits symbols state start current result checkedResult pair next nativeResult value \
  \typed native inner failure subject steps"

-- | Each definition's and spec handler's function, named after it, unique
-- across the bodies and workflows modules.
functionNames :: [Unit] -> ([(Id, String)], [(Id, String)])
functionNames units = (zip (map (declarationId . definitionDeclaration) definitions) definitionNames',
  zip (map handlerId handlers) handlerNames)
  where
    definitions = concatMap unitDefinitions units
    handlers = concatMap unitHandlers units
    (chosen, _) = claimAll (scopeWith moduleNames)
      (map base definitions ++ [nativeIdentifier "haskell" FunctionName (handlerName h ++ " handler") | h <- handlers])
    (definitionNames', handlerNames) = splitAt (length definitions) chosen
    base d = let declaration = definitionDeclaration d
      in nativeIdentifier "haskell" FunctionName
           (readableDefinitionName (declarationName declaration) (fst (functionType (declarationType declaration))))

-- | Workflows call adapters, so they live in LawSpecWorkflows, apart from the
-- bodies adapters may import.
definitionCalls :: [Unit] -> [(Id,String)]
definitionCalls units = [(declarationId (definitionDeclaration d),
  (if definitionOrchestrates d then "Workflows." else "Definitions.") ++ name)
  | (d, (_, name)) <- zip (concatMap unitDefinitions units) (fst (functionNames units))]

-- A spec handler's function: they live with the bodies, which call them for
-- handle ... with h end, and which their clauses call.
specHandlerCall :: [Unit] -> Id -> String
specHandlerCall units h = "Definitions." ++ maybe "undefinedHandler" id (lookup h (snd (functionNames units)))

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
      body x@(_, d) = maybe (implementation contracts "Definitions" x) (bridge typed d)
        (hsTypedFunction typed (declarationId (definitionDeclaration d)))
  bodies <- (++) <$> mapM body [x | x@(_, d) <- indexed, not (definitionOrchestrates d)]
    <*> mapM (\h -> if isTypedHandler plan h then typedSpec typed h else spec h) (concatMap unitHandlers units)
  workflows <- mapM (implementation contracts "Workflows") [x | x@(_, d) <- indexed, definitionOrchestrates d]
  wrappers <- mapM (nativeUnit False) (filter (any (not . definitionOrchestrates) . unitDefinitions) units)
  workflowWrappers <- mapM (nativeUnit True) (filter (any definitionOrchestrates . unitDefinitions) units)
  let adapterImports = nub [(moduleOf owner, Just (moduleOf owner), Nothing) | (_, (owner, _)) <- adapters]
      typedFiles = if hasTyped
        then [ Artifact "src/LawSpecTyped.hs" (hsTypedModule typed) "generated" "source"
             , Artifact "src/LawSpecFast.hs" (runtimeSource "haskell-fast") "generated" "source" ]
        else []
  pure (typedFiles ++ file "LawSpecDefinitionBodies" [] True bodies :
    [file "LawSpecWorkflows" (("LawSpecDefinitionBodies", Just "Definitions", Nothing) : adapterImports) True workflows
    | not (null workflows)] ++
    wrappers ++ workflowWrappers)
  where
    names = definitionCalls units
    (_, handlerNames) = functionNames units
    sourceFile = listToMaybe (mapMaybe unitSourceFile units)
    orFail x = call "P.either" [var "P.error", var "P.id", x]
    symbolsArg = var "symbols"
    justSymbols = call "P.Just" [symbolsArg]
    codecOf = Native.haskellCodecDocWithContext justSymbols declarations "schema" "machineBits"
    -- The one-line comment linking a function to its source.
    linked label origin = H.comment [labelled label (sourceLink origin)]
    definitionLink d = linked (declarationName (definitionDeclaration d)) (declarationOrigin (definitionDeclaration d))
    -- A definition's argument names, from the source.
    argumentNames d = fst (claimAll (scopeWith (moduleNames ++ map snd handlerNames ++ map (unqualified . snd) names))
      [H.localName (binderName b) | b <- definitionArguments d])
    unqualified n = drop 1 (dropWhile (/= '.') n)
    -- A typed definition's dynamic entry converts its arguments and result.
    bridge typed d function = do
      let (argTypes, resultType) = functionType (declarationType (definitionDeclaration d))
          identity = declarationId (definitionDeclaration d)
          arguments = take (length argTypes) (argumentNames d ++ ["value" ++ show i | i <- [length (definitionArguments d) ..]])
          name = functionName d
          typedCall = call ("Typed." ++ function) ([symbolsArg | isContextual (hsTypedPlan typed) identity] ++
            [call ("Typed." ++ hsTypedFrom typed t) [var a] | (t, a) <- zip argTypes arguments])
      pure (D.joinWith D.hardline [definitionLink d,
        H.signature name (["LS.SymbolContext"] ++ replicate (length arguments) "LS.Scalar" ++ ["P.Either P.String LS.Scalar"]),
        H.declaration (unwords (name : "symbols" : arguments))
          (call "P.Right" [call "LS.performIO" [call "P.fmap" [var ("Typed." ++ hsTypedTo typed resultType), typedCall]]])])
    functionName d = maybe "undefinedDefinition" unqualified (lookup (declarationId (definitionDeclaration d)) names)
    handlerFunction h = maybe "undefinedHandler" id (lookup (handlerId h) handlerNames)
    record con fields = H.Record con fields
    -- A typed spec handler keeps its typed state in an MVar: each operation
    -- converts its arguments, runs the typed clause and keeps the next state,
    -- which shares all it did not change with the state before. Operations
    -- apply one at a time, and a failing one leaves the state as it was.
    typedSpec typed h = do
      answered <- forM (handlerAbilities h) $ \ref -> do
        (_, ability) <- maybe (Left ("unknown ability of handler " ++ handlerName h)) Right (findAbility units ref)
        pure (ref, ability)
      let name = handlerFunction h
          recordOf (ref, ability) = typesModuleOf ref ++ "." ++ interfaceName ability
          qualifierOf (ref, _) = typesModuleOf ref ++ "."
          plan = hsTypedPlan typed
          stateful = handlerState h /= Nothing
      stateType <- case handlerState h of
        Just (t, _) -> hsTypedType typed t
        Nothing -> pure "()"
      start <- case handlerState h of
        Nothing -> pure [Bind "state" (call "MVar.newMVar" [var "()"])]
        Just _ -> do
          made <- maybe (Left ("untyped start of " ++ handlerName h)) Right (hsTypedStart typed (handlerId h))
          pure [Bind "start" (call ("Typed." ++ made) [symbolsArg]), Bind "state" (call "MVar.newMVar" [var "start"])]
      let recordFor answer@(_, ability) = do
            fields <- forM (abilityOperations ability) $ \(op, ty) -> do
              clause <- maybe (Left (handlerName h ++ ": no clause for " ++ op)) Right (lookup op (handlerClauses h))
              function <- maybe (Left ("untyped clause " ++ idText clause)) Right (hsTypedFunction typed clause)
              let (args, result) = functionType ty
                  values = H.uniqueValues (length args)
                  arguments' = H.uniqueArguments (length args)
                  inputs = [H.Let ("!" ++ a) (call ("Typed." ++ hsTypedFromNative typed t) [var v]) | (a, (t, v)) <- zip arguments' (zip args values)]
                  arguments = ["symbols" | isContextual plan clause] ++ ["current" | stateful] ++
                    (if null args && not stateful then ["()"] else arguments')
                  invocation = call ("Typed." ++ function) (map var arguments)
                  out = Run (operator "P.$!" [var "P.pure", call ("Typed." ++ hsTypedToNative typed result) [var "result"]])
                  steps = H.Do (inputs ++
                    (if stateful
                      then [ Bind "result" (call "MVar.modifyMVar" [var "state", lambda ["current"] (H.Do
                               [ Bind "!pair" invocation
                               , Run (H.Case (var "pair") [(hsTypedPair typed ++ " r n", call "P.pure" [H.Tuple [var "n", var "r"]])]) ])]) ]
                      else [Bind "!result" invocation]) ++ [out])
              pure (qualifierOf answer ++ fieldName ability op, if null values then steps else lambda values steps)
            pure (call "P.pure" [record (recordOf answer) fields])
      -- The state, read and replaced in its native types.
      access <- case handlerState h of
        Nothing -> pure []
        Just (t, _) -> do
          native <- Native.haskellDataType declarations t
          let parenthesized x = if ' ' `elem` x && take 1 x /= "(" && take 1 x /= "[" then "(" ++ x ++ ")" else x
          pure [ D.joinWith D.hardline
                 [ H.comment ["The state of " ++ handlerName h ++ ", in its native types: a snapshot to show or keep."]
                 , H.signature (name ++ "Snapshot") ["MVar.MVar " ++ stateType, "P.IO " ++ parenthesized native]
                 , H.declaration (name ++ "Snapshot state") (call "P.fmap" [var ("Typed." ++ hsTypedToNative typed t), call "MVar.readMVar" [var "state"]]) ]
               , D.joinWith D.hardline
                 [ H.comment ["Replaces the state of " ++ handlerName h ++ ": to force it, reset it or restore a snapshot."]
                 , H.signature (name ++ "Restore") ["MVar.MVar " ++ stateType, parenthesized native, "P.IO ()"]
                 , H.declaration (name ++ "Restore state native") (H.Do
                     [ H.Let "!typed" (call ("Typed." ++ hsTypedFromNative typed t) [var "native"])
                     , Run (call "MVar.modifyMVar_" [var "state", lambda ["_"] (call "P.pure" [var "typed"])]) ]) ] ]
      case answered of
        [answer@(_, ability)] | not stateful -> do
          made <- recordFor answer
          pure (D.joinWith D.hardline
            [ linked ("spec handler " ++ handlerName h ++ " for " ++ abilityName ability) (handlerOrigin h)
            , H.signature name ["LS.SymbolContext", "P.IO " ++ recordOf answer]
            , H.declaration (name ++ " symbols") (H.Do (start ++ [Bind "_" (call "P.pure" [var "state"]), Run made])) ])
        _ -> do
          parts <- forM answered $ \answer@(_, ability) -> do
            made <- recordFor answer
            let part = name ++ abilityName ability
            pure (D.joinWith D.hardline
              [ H.comment [handlerName h ++ " as a " ++ abilityName ability ++ " handler, over its typed state."]
              , H.signature part ["LS.SymbolContext", "MVar.MVar " ++ stateType, "P.IO " ++ recordOf answer]
              , H.declaration (part ++ " symbols state") (H.Do [Bind "_" (call "P.pure" [var "state"]), Run made]) ])
          let stateDoc = D.joinWith D.hardline
                [ linked ("spec handler " ++ handlerName h ++ "'s typed state, made afresh") (handlerOrigin h)
                , H.signature (name ++ "State") ["LS.SymbolContext", "P.IO (MVar.MVar " ++ stateType ++ ")"]
                , H.declaration (name ++ "State symbols") (H.Do (start ++ [Run (call "P.pure" [var "state"])])) ]
              (firstRef, firstAbility) = case answered of { a : _ -> a; [] -> error "a handler of no ability" }
              freshDoc = D.joinWith D.hardline
                [ H.comment ["The spec handler " ++ handlerName h ++ " as a " ++ abilityName firstAbility ++ " handler, with its own state."]
                , H.signature name ["LS.SymbolContext", "P.IO " ++ recordOf (firstRef, firstAbility)]
                , H.declaration (name ++ " symbols") (operator "P.>>=" [call (name ++ "State") [symbolsArg], call (name ++ abilityName firstAbility) [symbolsArg]]) ]
          pure (D.joinWith (D.hardline <> D.hardline) (stateDoc : freshDoc : parts ++ access))
    -- A module of functions, with its imports (only those it uses), the
    -- program's schema and machine width, and its functions.
    file name extraImports environment bodies =
      let bodyText = D.render D.Compact (D.joinWith D.hardline bodies)
          uses w = w `elem` words (map (\c -> if isAlphaNum c then c else ' ') bodyText)
          declarations' = [D.joinWith D.hardline [H.comment ["The program's types, which values are checked against."],
              H.signature "schema" ["Schema.Schema"], H.declaration "schema" (call "P.either" [var "P.error", var "P.id", var "DataSchema.schema"])]
              | environment, uses "schema"] ++
            [D.joinWith D.hardline [H.comment ["The machine profile's integer width."],
              H.signature "machineBits" ["P.Int"], H.declaration "machineBits" (integer (toInteger bits))] | environment, uses "machineBits"] ++ bodies
          rendered = D.render D.Compact (D.joinWith D.hardline declarations')
          imports = moduleImports rendered (
            [("Prelude", Just "P", Nothing), ("Data.Int", Just "I", Nothing), ("Data.Word", Just "W", Nothing),
             ("Data.Text", Just "T", Nothing), ("Data.ByteString", Just "B", Nothing), ("Data.Complex", Just "C", Nothing),
             ("Data.IORef", Just "IORef", Nothing), ("LawSpecRuntime", Nothing, Just ["Scalar (..)"]),
             ("LawSpecRuntime", Just "LS", Nothing), ("LawSpecSchema", Just "Schema", Nothing),
             ("LawSpecCodecs", Just "Codec", Nothing), ("LawSpecData", Just "Data", Nothing),
             ("LawSpecDataSchema", Just "DataSchema", Nothing), ("LawSpecDataCodecs", Just "Codecs", Nothing),
             ("LawSpecTyped", Just "Typed", Nothing), ("LawSpecFast", Just "LSF", Nothing),
             ("Control.Concurrent.MVar", Just "MVar", Nothing)] ++
            concat [[("LawSpecCollectionCodecs", Just "Collections", Nothing), ("Data.Set", Just "Set", Nothing),
                     ("Data.Map.Strict", Just "Map", Nothing), ("Data.Sequence", Just "Seq", Nothing)]
                   | any (isCollectionsType . idText . dataId) declarations] ++
            [(m, Just m, Nothing) | (m, _, _) <- abilityImports] ++ extraImports)
      in Artifact ("src/" ++ map (\c -> if c == '.' then '/' else c) name ++ ".hs")
      (D.render layout (D.joinWith D.hardline (map D.text
        (["-- " ++ generatedHeader sourceFile, "{-# LANGUAGE BangPatterns #-}"] ++
         -- Each performed operation must run where it is written, once.
         ["{-# OPTIONS_GHC -fno-cse -fno-full-laziness #-}" | performing] ++
         ["", "module " ++ name ++ " where", ""] ++ imports ++ [""])) <>
        D.hardline <> D.joinWith (D.hardline <> D.hardline) declarations' <> D.hardline)) "generated" "source"
    context identity body = H.dollarIn "P." (call "Codec.context" [string (idText identity)]) (H.Do body)
    adapters = [ (callee, (owner, adapter)) | d <- concatMap unitDefinitions units, definitionOrchestrates d
               , callee <- callsIn (definitionBody d), Just (owner, adapter) <- [lookup callee adapterTable] ]
    adapterTable = [(declarationId d, (unitId u, d)) | u <- units, d <- unitDeclarations u,
      declarationId d `notElem` map (declarationId . definitionDeclaration) (concatMap unitDefinitions units)]
    callsIn expression = case expressionNode expression of
      ExternalCall callee arguments -> callee : concatMap callsIn arguments
      _ -> concatMap callsIn (children expression)
    moduleOf owner = intercalate "." (map modulePart (split '.' (idText owner)))
    -- An adapter that fails with E: its native code throws LS.Fail with a
    -- native E.
    failing adapter = failingAs [a | a@(AbilityRef _ [_]) <- declarationUses adapter, isFail a]
    failingAs failures call' = case failures of
      ability@(AbilityRef _ [failure]) : _ ->
        let codec = either error id (codecOf failure)
            native = either error id (Native.haskellDataType declarations failure)
        in call "LS.nativeFailures" [string (abilityKey ability),
             H.Typed (call "Codec.encoded" [codec]) (native ++ " -> LS.Scalar"),
             lambda ["()"] call', H.List []]
      _ -> call'
    abilityOwner ability = fst <$> findAbility units ability
    typesModuleOf ability = maybe "LawSpecAbilities" (\u -> "LawSpecAbilities." ++ moduleOf (unitId u)) (abilityOwner ability)
    -- A spec handler: a record of its ability's operations, each running its
    -- clause (a handler with state keeps it in an IORef).
    spec h = do
      answered <- forM (handlerAbilities h) $ \ref -> do
        (_, ability) <- maybe (Left ("unknown ability of handler " ++ handlerName h)) Right (findAbility units ref)
        pure (ref, ability)
      let name = handlerFunction h
          recordOf (ref, ability) = typesModuleOf ref ++ "." ++ interfaceName ability
          qualifierOf (ref, _) = typesModuleOf ref ++ "."
          stateful = handlerState h /= Nothing
          unitValue = call "LS.SAbsent" [string "Unit"]
      start <- case handlerState h of
        Nothing -> pure []
        -- A computed start value is its own definition (<handler>Start).
        Just (_, Expr _ (ExternalCall startDefinition _) _) -> do
          evaluate <- maybe (Left ("unresolved start of " ++ handlerName h)) Right (lookup startDefinition names)
          pure [Bind "state" (operator "P.=<<" [var "IORef.newIORef", call "LS.runClause" [call (unqualified evaluate) [symbolsArg, unitValue]]])]
        Just (_, value) -> do
          let startLocals = zip (map binderId (nestedBinders value))
                (fst (claimAll (scopeWith moduleNames) [H.localName (binderName b) | b <- nestedBinders value]))
          rendered <- E.renderExpression declarations bits "schema" "symbols" (\i -> maybe "start" id (lookup i startLocals))
            (\_ _ -> Left "a handler's start value calls nothing") value
          pure [Bind "state" (call "IORef.newIORef" [rendered])]
      -- The record of one ability's operations, each running its clause.
      let recordFor answer@(_, ability) = do
            fields <- forM (abilityOperations ability) $ \(op, ty) -> do
              clause <- maybe (Left (handlerName h ++ ": no clause for " ++ op)) Right (lookup op (handlerClauses h))
              evaluate <- maybe (Left ("unresolved clause " ++ idText clause)) Right (lookup clause names)
              let (args, result) = functionType ty
                  values = H.uniqueValues (length args)
                  arguments' = H.uniqueArguments (length args)
              codecs <- mapM codecOf args
              resultCodec <- codecOf result
              let inputs = [Bind a (call "Codec.encode" [c, var v]) | (a, (c, v)) <- zip arguments' (zip codecs values)]
                  arguments = [symbolsArg] ++ [var "current" | stateful] ++
                    (if null args && not stateful then [unitValue] else map var arguments')
                  invocation = call (unqualified evaluate) arguments
                  steps = if not stateful
                    then call "LS.runClause" [H.Do (inputs ++ [Bind "result" invocation, Run (call "Codec.decode" [resultCodec, var "result"])])]
                    else H.Do
                      [ Bind "current" (call "IORef.readIORef" [var "state"])
                      , Bind "(result, next)" (call "LS.runClause" [H.Do (inputs ++ [Bind "pair" invocation, Run (call "P.pure" [call "LS.pairFields" [var "pair"]])])])
                      , Run (call "IORef.writeIORef" [var "state", var "next"])
                      , Run (call "LS.runClause" [call "Codec.decode" [resultCodec, var "result"]]) ]
              pure (qualifierOf answer ++ fieldName ability op, if null values then steps else lambda values steps)
            pure (call "P.pure" [record (recordOf answer) fields])
      case answered of
        [answer@(_, ability)] -> do
          made <- recordFor answer
          pure (D.joinWith D.hardline
            [ linked ("spec handler " ++ handlerName h ++ " for " ++ abilityName ability) (handlerOrigin h)
            , H.signature name ["LS.SymbolContext", "P.IO " ++ recordOf answer]
            , H.declaration (name ++ " symbols") (H.Do (start ++ [Run made])) ])
        _ -> do
          -- A handler of several abilities: its state, made once, and a
          -- record for each ability over it (handlerPart).
          parts <- forM answered $ \answer@(_, ability) -> do
            made <- recordFor answer
            let part = name ++ abilityName ability
            pure (D.joinWith D.hardline
              [ H.comment [handlerName h ++ " as a " ++ abilityName ability ++ " handler, over its state."]
              , H.signature part ["LS.SymbolContext", "IORef.IORef LS.Scalar", "P.IO " ++ recordOf answer]
              , H.declaration (part ++ " symbols state") (H.Do [Bind "_" (call "P.pure" [var "state"]), Run made]) ])
          let stateDoc = D.joinWith D.hardline
                [ linked ("spec handler " ++ handlerName h ++ "'s state, made afresh") (handlerOrigin h)
                , H.signature (name ++ "State") ["LS.SymbolContext", "P.IO (IORef.IORef LS.Scalar)"]
                , H.declaration (name ++ "State symbols") (H.Do ((if stateful then start else [Bind "state" (call "IORef.newIORef" [unitValue])]) ++
                    [Bind "_" (call "P.pure" [symbolsArg]), Run (call "P.pure" [var "state"])])) ]
              (firstRef, firstAbility) = case answered of { a : _ -> a; [] -> error "a handler of no ability" }
              freshDoc = D.joinWith D.hardline
                [ H.comment ["The spec handler " ++ handlerName h ++ " as a " ++ abilityName firstAbility ++ " handler, with its own state."]
                , H.signature name ["LS.SymbolContext", "P.IO " ++ recordOf (firstRef, firstAbility)]
                , H.declaration (name ++ " symbols") (operator "P.>>=" [call (name ++ "State") [symbolsArg], call (name ++ abilityName firstAbility) [symbolsArg]]) ]
          pure (D.joinWith (D.hardline <> D.hardline) (stateDoc : freshDoc : parts))
    operationOf op = typesModuleOf (operationAbility op) ++ "." ++
      maybe (operationName op) (\(_, a) -> fieldName a (operationName op)) (findAbility units (operationAbility op))
    handlerOf ability = call "LS.handlerOf" [symbolsArg, string (abilityKey ability)]
    abilityImports = [("LawSpecAbilities." ++ moduleOf (unitId u), Just ("LawSpecAbilities." ++ moduleOf (unitId u)), Nothing :: Maybe [String])
      | u <- units, not (null (unitAbilities u))]
    performing = any (not . null . unitAbilities) units
    evaluator localName identity = maybe (Left "unresolved Haskell policy definition") (Right . localName) (lookup identity names)
    scalarInteger n = call "LS.SInteger" [string "Integer", integer n]
    policyDoc localName key policy = do
      gates <- policyGates localName policy
      compensate <- case policyCompensate policy of
        Nothing -> pure (var "P.Nothing")
        Just undo -> (\name -> call "P.Just" [lambda ["value"] (orFail (call name [symbolsArg, var "value"]))]) <$> evaluator localName undo
      retry <- case policyRetry policy of
        Nothing -> pure (var "P.Nothing")
        Just r -> do
          let (kind, delay, step, factor, cap) = case retryStrategy r of
                Immediate -> ("immediate", 0, 0, 0, -1)
                Fixed d' -> ("fixed", d', 0, 0, -1)
                Linear d' s' -> ("linear", d', s', 0, -1)
                Exponential d' f c -> ("exponential", d', 0, f, maybe (-1) id c)
                Fibonacci d' -> ("fibonacci", d', 0, 0, -1)
                Custom _ -> ("custom", 0, 0, 0, -1)
          condition <- case retryWhen r of
            Nothing -> pure (var "P.Nothing")
            Just p -> (\name -> call "P.Just" [lambda ["failure"] (call "LS.truth" [orFail (call name [symbolsArg, var "failure"])])]) <$> evaluator localName p
          decide <- case retryStrategy r of
            Custom f -> (\name -> call "P.Just" [lambda ["attempt", "failure", "previous"] (call "LS.retryDecision" [orFail (call name
              [symbolsArg, call "LS.SInteger" [string "Integer", var "attempt"], var "failure", call "LS.durationScalar" [var "previous"]])])]) <$> evaluator localName f
            _ -> pure (var "P.Nothing")
          pure (call "P.Just" [call "LS.Retry" [string kind, integer delay, integer step, integer factor, integer cap,
            integer (retryAttempts r), string (jitterName (retryJitter r)), condition, decide]])
      pure (call "LS.StagePolicy" [string (policyStage policy), retry, integer (maybe (-1) id (policyTimeout policy)),
        string key, H.List gates, integer (maybe (-1) id (policyCache policy)),
        var (if null (policyFailures policy) then "P.False" else "P.True"), compensate,
        maybe (var "P.Nothing") (\h -> call "P.Just" [H.Tuple [integer (hedgeDelay h), integer (toInteger (hedgeMost h))]]) (policyHedge policy)])
    -- A gate's callbacks call the unit's copies of the resilience unit's
    -- state machines, with the policy's numbers.
    policyGates localName policy = do
      let now = call "LS.SInteger" [string "Integer", var "now"]
          gate kind start admit finish wait = call "LS.Gate" [string kind, lambda ["now"] (orFail start),
            lambda ["state", "now"] (orFail admit),
            maybe (var "P.Nothing") (\f -> call "P.Just" [lambda ["state", "now", "succeeded"] (orFail f)]) finish, integer wait]
          waitCode wait = case wait of
            Nothing -> -2
            Just Nothing -> -1
            Just (Just d') -> d'
      breaker <- forM (policyBreaker policy) $ \b -> do
        start <- evaluator localName (breakerStart b)
        admit <- evaluator localName (breakerAdmit b)
        record' <- evaluator localName (breakerRecord b)
        pure (gate "breaker" (call start [symbolsArg, now]) (call admit [symbolsArg, var "state", now])
          (Just (call record' ([symbolsArg] ++ map scalarInteger [breakerFailures b, breakerWindow b, breakerCooldown b] ++
            [var "state", now, call "LS.SBool" [var "succeeded"]]))) (-2))
      limit <- forM (policyLimit policy) $ \l -> do
        start <- evaluator localName (limitStart l)
        admit <- evaluator localName (limitAdmit l)
        let numbers = map scalarInteger [limitCount l, limitPeriod l]
        pure (gate "limit" (call start ([symbolsArg] ++ numbers ++ [now])) (call admit ([symbolsArg] ++ numbers ++ [var "state", now]))
          Nothing (waitCode (limitWait l)))
      bulkhead <- forM (policyBulkhead policy) $ \b -> do
        start <- evaluator localName (bulkheadStart b)
        admit <- evaluator localName (bulkheadAdmit b)
        release <- evaluator localName (bulkheadRelease b)
        let n = [scalarInteger (bulkheadLimit b)]
        pure (gate "bulkhead" (call start ([symbolsArg] ++ n ++ [now])) (call admit ([symbolsArg] ++ n ++ [var "state", now]))
          (Just (call release [symbolsArg, var "state"])) (waitCode (bulkheadWait b)))
      pure (maybe [] pure breaker ++ maybe [] pure limit ++ maybe [] pure bulkhead)
    jitterName j = case j of
      NoJitter -> "none" :: String
      FullJitter -> "full"
      EqualJitter -> "equal"
      DecorrelatedJitter -> "decorrelated"
    implementation contracts home (_,d) = do
      let binders = definitionArguments d ++ nestedBinders (definitionBody d)
          locals = zip (nub (map binderId binders)) (fst (claimAll (scopeWith (moduleNames ++ map snd handlerNames ++ map (unqualified . snd) names))
            [H.localName (binderName b) | b <- nubOn binderId binders]))
          local identity = maybe (error "unresolved Haskell local") id (lookup identity locals)
          arguments = map (local . binderId) (definitionArguments d)
          name = functionName d
          -- Calls within the same module are unqualified.
          localName callee = case break (== '.') callee of
            (prefix, '.' : rest) | prefix == home -> rest
            _ -> callee
          external term values = case expressionNode term of
            ExternalCall identity _ | Just callee <- lookup identity names ->
              pure (orFail (call (localName callee) (symbolsArg : values)))
            -- handle e with h end: e runs with h installed for its ability,
            -- made afresh each time.
            Handle (WithHandler ability (SpecHandler h)) _ | [body] <- values ->
              pure (call "LS.withHandlers" [symbolsArg,
                call "P.sequence" [H.List [call "P.fmap" [call "LS.installed" [string (abilityKey ability)], call (localName (specHandlerCall units h)) [symbolsArg]]]],
                lambda ["()"] body])
            -- raise aborts to the nearest attempt of its Fail ability.
            Perform op [_] | isFail (operationAbility op) ->
              pure (call "LS.raiseFailure" (string (abilityKey (operationAbility op)) : values))
            -- An operation goes to the handler installed with the symbol
            -- context for its ability (evidence passing), through the codecs.
            Perform op args -> do
              codecs <- mapM (codecOf . expressionType) args
              resultCodec <- codecOf (expressionType term)
              let performed = call "LS.performIO" [call (operationOf op) (handlerOf (operationAbility op) :
                    [call "Codec.decoded" [codec, value] | (codec, value) <- zip codecs values])]
              -- An operation that fails with E: a native handler throws
              -- LS.Fail with a native E, which becomes the failure.
              pure (failingAs (maybe [] pure (findAbility units (operationAbility op) >>= lookup (operationName op) . abilityFailures . snd))
                (call "Codec.encoded" [resultCodec, performed]))
            -- prelude.attempt e: Right of e's value, or Left of its failure.
            Handle (CatchFailure ability) _ | [body] <- values, Constructor "Either" [TypeArgument failure, TypeArgument result] <- expressionType term -> do
              let placeholder = Id "lawspec::attempt::value"
                  side tag ty = do
                    made <- E.renderExpression declarations bits "schema" "symbols" (\i -> if i == placeholder then "value" else local i) external
                      (Expr (expressionType term) (Construct (Id tag) [Expr ty (Local placeholder) (GeneratedFrom placeholder)]) (GeneratedFrom placeholder))
                    pure (lambda ["value"] made)
              right <- side "Either::Right" result
              left <- side "Either::Left" failure
              pure (call "LS.attempt" [string (abilityKey ability), body, right, left])
            -- A workflow calls an adapter natively, through the codecs.
            ExternalCall identity _ | Just (owner, adapter) <- lookup identity adapterTable -> do
              let (parameterTypes, resultType) = functionType (declarationType adapter)
              codecs <- mapM codecOf parameterTypes
              resultCodec <- codecOf resultType
              -- An adapter that uses abilities gets their handlers first, and
              -- runs in IO.
              let handlers = [handlerOf a | a <- declarationUses adapter, not (isFail a)]
                  plain = call (moduleOf owner ++ "." ++ declarationName adapter)
                    ([symbolsArg | identity `elem` bound] ++ handlers ++
                     [call "Codec.decoded" [codec, value] | (codec, value) <- zip codecs values])
                  adapterCall = if null handlers || declarationAsync adapter then plain else call "LS.performIO" [plain]
              -- An async step runs within its stage's timeout and hedge,
              -- when it has them.
              pure $ if declarationAsync adapter
                then call "LS.awaitStep" [symbolsArg, adapterCall, call "Codec.encoded" [resultCodec]]
                else failing adapter (call "Codec.encoded" [resultCodec, adapterCall])
            _ -> Left "unresolved Haskell total call"
      rendered <- E.renderExpression declarations bits "schema" "symbols" local external (definitionBody d)
      -- A workflow stage with policies runs under the workflow runtime.
      body <- case definitionPolicy d of
        Nothing -> pure rendered
        Just policy | policyFrame policy -> pure (call "LS.runWorkflow" [symbolsArg, lambda ["()"] rendered])
        Just policy -> do
          config <- policyDoc localName (idText (declarationId (definitionDeclaration d))) policy
          let key = case arguments of
                argument : _ -> var argument
                [] -> call "LS.SAbsent" [string "Unit"]
          pure (call "LS.runStage" [symbolsArg, config, lambda ["()"] rendered, key])
      let evaluate = H.Let "result" body
          checkedResult = call "LS.forcing" [H.List [var "result"], call "P.pure" [var "result"]]
          contract = lookup (declarationId (definitionDeclaration d))
            [(contractDeclaration c,c) | c <- contracts]
      statements <- case contract of
        Nothing -> pure [evaluate, Run checkedResult]
        Just c -> do
          let aliases = zip (map binderId (contractArguments c))
                (map (local . binderId) (definitionArguments d)) ++
                [(binderId (contractResult c),"checkedResult")] ++
                [(binderId b,"contractValue" ++ show i) | (i,b) <- zip [0::Int ..]
                  (concatMap nestedBinders (contractPreconditions c ++ contractPostconditions c ++ contractRuntimePostconditions c))]
              resolve identity = maybe (error "unbound Haskell definition contract binder") id (lookup identity aliases)
              require stage predicate = do
                expression <- E.renderExpression declarations bits "schema" "symbols" resolve external predicate
                pure (Run (H.If (call "LS.truth" [expression]) (call "P.Right" [var "()"]) (call "P.Left" [string (stage ++ " failed")])))
          pre <- mapM (require "precondition") (contractPreconditions c)
          -- Proved by the totality audit; see LawSpec.Core.Evidence.
          post <- mapM (require "postcondition") (runtimePostconditions c)
          pure (pre ++ [evaluate, Bind "checkedResult" checkedResult] ++ post ++ [Run (call "P.Right" [var "checkedResult"])])
      pure (D.joinWith D.hardline [definitionLink d,
        H.signature name (["LS.SymbolContext"] ++ replicate (length arguments) "LS.Scalar" ++ ["P.Either P.String LS.Scalar"]),
        H.declaration (unwords (name : "symbols" : arguments)) (context (declarationId (definitionDeclaration d)) statements)])
    nubOn f = foldr (\x seen -> if any ((== f x) . f) seen then seen else x : seen) [] . reverse
    nativeUnit workflows unit = do
      methods <- mapM native [d | d <- unitDefinitions unit, definitionOrchestrates d == workflows]
      let name = (if workflows then "LawSpecWorkflows." else "LawSpecDefinitions.") ++
            intercalate "." (map modulePart (split '.' (idText (unitId unit))))
      pure (file name ([if workflows then ("LawSpecWorkflows", Just "Workflows", Nothing)
        else ("LawSpecDefinitionBodies", Just "Definitions", Nothing)] ++
        -- The handlers a definition takes are its abilities' owners' records.
        nub [("LawSpecAbilities." ++ moduleOf (unitId owner), Just ("LawSpecAbilities." ++ moduleOf (unitId owner)), Nothing) | d <- unitDefinitions unit
            , ability <- declarationUses (definitionDeclaration d), not (isFail ability), Just (owner, _) <- [findAbility units ability]]) True methods)
    native d = do
      let declaration = definitionDeclaration d
          (args,result) = functionType (declarationType declaration)
          name = declarationName declaration
          values = take (length args) (argumentNames d ++ ["value" ++ show i | i <- [length (definitionArguments d) ..]])
      types <- mapM (Native.haskellDataType declarations) args
      resultType <- Native.haskellDataType declarations result
      codecs <- mapM codecOf args
      resultCodec <- codecOf result
      callee <- maybe (Left "unresolved native Haskell call") Right (lookup (declarationId declaration) names)
      let handlers = [ (ability, lowerFirst (interfaceName a), "LawSpecAbilities." ++ moduleOf (unitId u) ++ "." ++ interfaceName a)
                     | ability <- declarationUses declaration, not (isFail ability)
                     , Just (u, a) <- [findAbility units ability] ]
          arguments' = H.uniqueArguments (length args)
          -- Native code passes a definition's handlers explicitly; they are
          -- installed with the symbol context, where its operations find them.
          installs = [Bind "()" (call "P.Right" [call "LS.performIO" [call "LS.installHandlers" [symbolsArg,
            H.List [call "LS.installed" [string (abilityKey ability), var n] | (ability, n, _) <- handlers]]]])
            | not (null handlers)]
          checks = installs ++ [Bind a (call "Codec.encode" [codec, var value]) | (a, (codec, value)) <- zip arguments' (zip codecs values)]
          invoke = call callee (symbolsArg : map var arguments')
          wrapType t = if ' ' `elem` t && take 1 t /= "(" && take 1 t /= "[" then "(" ++ t ++ ")" else t
      pure (D.joinWith D.hardline [definitionLink d,
        H.signature name (["LS.SymbolContext"] ++ [iface | (_, _, iface) <- handlers] ++ map wrapType types ++
          ["P.Either P.String " ++ wrapType resultType]),
        H.declaration (unwords (name : "symbols" : [n | (_, n, _) <- handlers] ++ values)) (context (declarationId declaration)
          (checks ++ [Bind "result" invoke, Run (call "Codec.decode" [resultCodec, var "result"])]))])
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
