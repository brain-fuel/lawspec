-- | How each law of a checked program is discharged, alongside the contract,
-- construction and adapter obligations of LawSpec.Core.Evidence and the
-- native bindings of a generation request. Strongest first:
--
--   proved                a law over checked definitions only, discharged by the
--                         totality audit's prover, like a definition postcondition
--   exhaustively-checked  every input of a finite domain is checked: by the
--                         compiler when the law calls definitions only (a false
--                         law is then a compile error), otherwise by the
--                         generated tests
--   property-tested       generated cases, boundary cases and examples
--   runtime-checked       contracts and codecs checked at native boundaries
--   assumed               native adapters, bindings and generators on trust
{-# OPTIONS_GHC -fno-cse -fno-full-laziness #-}
module LawSpec.Discharge
  ( dischargeEvidence, bindingEvidence, defaultHandlerEvidence, lawClaim
  ) where

import Control.Monad (forM)
import Data.List (intercalate, isPrefixOf)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import LawSpec.Common
import LawSpec.Core
import LawSpec.Core.DefinitionContracts (definitionContracts)
import LawSpec.Core.Definitions (prepareHookedDefinitions)
import LawSpec.Core.Eval (evaluateValueProposition, evaluateValue)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import System.IO.Unsafe (unsafePerformIO)
import LawSpec.Core.Evidence
import LawSpec.Core.Total (validateDefinitionContracts)
import LawSpec.Core.Types (makeRegistry, TypeRegistry)
import LawSpec.Core.Value (Value(..))
import LawSpec.NativeBinding
import LawSpec.NativeRequest (BindingPlan(..))
import LawSpec.Scalar (Scalar(..), prettyScalar)
import LawSpec.Builtins (defaultedUnits, defaultHandlerReason)
import LawSpec.Testing (PlannedProperty(..), lawPlanner)

-- | Laws first, then contracts, constructions and adapters. A law over checked
-- definitions whose finite domain contains a counterexample is refuted here.
dischargeEvidence :: Program -> Either [Diagnostic] [Obligation]
dischargeEvidence program = do
  hooked <- prepareHookedDefinitions program
  plan <- lawPlanner program
  registry <- either (Left . pure . (\m -> Diagnostic "generation" m Nothing)) Right
    (makeRegistry (programDataDeclarations program))
  let bits = programMachineBits program
      -- An orchestration calls adapters, so a law over one relies on them.
      definitions = filter (not . definitionOrchestrates) (concatMap unitDefinitions (programUnits program))
      definitionIds = S.fromList (map (declarationId . definitionDeclaration) definitions)
  laws <- forM [(u, p) | u <- programUnits program, p <- unitProperties u] $ \(u, original) -> do
    -- Under a spec handler without state, an operation is a call of its
    -- clause, so the law is over checked definitions only: the compiler can
    -- prove it, or evaluate a finite domain. Other operations stay opaque,
    -- which proofs allow (a law proved for an opaque operation holds for
    -- every handler) and evaluation does not.
    -- A spec handler with state answers its operations too: the compiler
    -- runs its clauses, threading the state through each case in the order
    -- the law performs them.
    let resolver = specResolver program original
        stateful = statefulResolver program original
        p = resolvePerforms resolver original
        hook states invoke' name = case M.lookup name resolver of
          Just clause -> Just (\values -> invoke' clause (if null values then [ScalarValue (SAbsent "Unit")] else values))
          Nothing -> case M.lookup name stateful of
            Just (h, clause) -> Just (step states h (invoke' clause))
            Nothing -> Nothing
        invokeWith states = hooked (hook states)
        obligation status reason = Obligation (unitId u) (propertyId p) "law" (Just (lawClaim original)) status reason
        called = S.fromList (concatMap callees (propertyExpressions p))
        adapters = S.toList (S.difference called definitionIds)
        reached = reachableDefinitions definitions (S.toList called)
        effects = any (effectful (`M.member` stateful)) (propertyExpressions p) ||
          any (\op -> M.notMember (operationId op) resolver && M.notMember (operationId op) stateful)
            (concatMap (performed . definitionBody) reached ++ concatMap performed (propertyExpressions p))
        natives = [ability | (ability, choice) <- propertyHandlers p, not (isFail ability), production choice]
        relying adapters' = relyingOn (adapters' ++ [Id ("the native " ++ abilityKey a ++ " handler") | a <- natives])
        -- A law with resources gets them when it runs, never from the compiler.
        closed = null adapters && null (propertyResources p)
        count n noun = show n ++ " " ++ noun ++ (if n == 1 then "" else "s")
        settings = propertyGeneration p
        every [_] = "its only case"
        every tuples = "all " ++ show (length tuples) ++ " inputs"
        harness = propertyHarness original
        byHarness = maybe "its harness" ("the harness " ++) (harnessUnit harness)
        -- The harness plane decides whether the tests run, never what a
        -- static proof or the compiler's own check established.
        tested status reason = case (harnessSkip harness, harnessKnownFailing harness) of
          (Just why, _) -> obligation Skipped ("skipped by " ++ byHarness ++ ": " ++ why ++ "; otherwise " ++ statusName status ++ ": " ++ reason)
          (_, Just why) -> obligation KnownFailing ("marked known failing by " ++ byHarness ++ ": " ++ why ++
            "; its tests must fail, and a run that passes is reported")
          _ -> obligation status reason
        static status reason = case harnessKnownFailing harness of
          Just _ -> Left [Diagnostic "harness" ("the law " ++ propertyName p ++ " is " ++ statusName status ++
            " by the compiler, so its harness cannot mark it known failing") (Just (propertyLocation p))]
          Nothing -> pure (obligation status (reason ++ maybe "" (const "; its harness skips its tests") (harnessSkip harness)))
    case plan p of
      Left message -> pure (tested Assumed ("not executable, so taken on trust: " ++ message))
      Right planned
        | closed, Right () <- proves program definitions p -> static Proved
            "proved statically from its input refinements and the definitions it calls"
        | closed, not effects, Just tuples <- finiteCases planned -> do
            mapM_ (\values -> do
              states <- freshStates registry bits (invokeWith Nothing) program original values
              refute registry bits (invokeWith states) p values) tuples
            static ExhaustivelyChecked ("the compiler evaluated " ++ every tuples ++
              "; the generated tests check " ++ (if length tuples == 1 then "it" else "them") ++ " again natively")
        | Just tuples <- finiteCases planned -> pure (tested ExhaustivelyChecked
            ("the generated tests check " ++ every tuples ++ relying adapters))
        | otherwise -> pure (tested PropertyTested
            ("the generated tests check " ++ count (cases settings) "generated case" ++ ", " ++
             count (length (boundaryCases planned)) "boundary case" ++ " and " ++
             count (length (propertyExamples p)) "example" ++ relying adapters))
  pure (laws ++ programEvidence program)
  where
    relyingOn [] = ""
    relyingOn adapters = "; relies on " ++ intercalate ", " (map idText adapters)
    production choice = case choice of
      ProductionHandler -> True
      RecordingHandler inner -> production inner
      SpecHandler _ -> False
    effectful answered e = case expressionNode e of
      Perform op args -> not (answered (operationId op)) || any (effectful answered) args
      Handle _ _ -> True
      Calls _ _ -> True
      Helper b _ | b `elem` [Recorded, AcquireResource, ReleaseResource, FreePort] -> True
      _ -> any (effectful answered) (children e)
    refute registry bits invoke p values = do
      let env = zip (map (binderId . quantifiedBinder) (propertyInputs p)) values
          at = Just (propertyLocation p)
          shown = intercalate ", " [binderName (quantifiedBinder q) ++ " = " ++ showValue v | (q, v) <- zip (propertyInputs p) values]
          input = if null shown then "" else " for " ++ shown
      case evaluateValueProposition registry bits invoke env (propertyBody p) of
        Right True -> pure ()
        Right False -> Left [Diagnostic "refuted" ("law " ++ propertyName p ++ " is false" ++ input) at]
        Left message -> Left [Diagnostic "refuted" ("law " ++ propertyName p ++ " fails" ++ input ++ ": " ++ message) at]

-- Each operation a law's spec handlers with state answer, by handler and
-- clause.
statefulResolver :: Program -> Property -> M.Map Id (Id, Id)
statefulResolver program p = M.fromList
  [ (operationId (Operation ability op), (handlerId h, clause))
  | (ability, choice) <- propertyHandlers p, Just h <- [specHandlerFor program choice], Just _ <- [handlerState h]
  , (op, clause) <- handlerClauses h ]

specHandlerFor :: Program -> HandlerRef -> Maybe Handler
specHandlerFor program choice = case choice of
  SpecHandler h -> lookup h [(handlerId x, x) | u <- programUnits program, x <- unitHandlers u]
  RecordingHandler inner -> specHandlerFor program inner
  ProductionHandler -> Nothing

-- The starting state of each spec handler with state a law runs under, in a
-- cell of its own for one case. (The values make each case's cell its own.)
freshStates :: TypeRegistry -> Int -> (Id -> [Value] -> Either String Value) -> Program -> Property -> [Value]
  -> Either [Diagnostic] (Maybe (IORef (M.Map Id Value)))
freshStates registry bits invoke program p values = do
  starts <- forM [h | (_, choice) <- propertyHandlers p, Just h <- [specHandlerFor program choice], Just _ <- [handlerState h]] $ \h ->
    case handlerState h of
      Just (_, start) -> either (\m -> Left [Diagnostic "refuted" (handlerName h ++ ": " ++ m) Nothing]) (Right . (,) (handlerId h))
        (evaluateValue registry bits invoke [] start)
      Nothing -> Left []
  if null starts then pure Nothing else pure (Just (cell (length values) (M.fromList starts)))

{-# NOINLINE cell #-}
cell :: Int -> M.Map Id Value -> IORef (M.Map Id Value)
cell salt initial = unsafePerformIO (salt `seq` newIORef initial)

-- One operation of a handler with state: its clause takes the state first
-- and gives Pair result state.
{-# NOINLINE step #-}
step :: Maybe (IORef (M.Map Id Value)) -> Id -> ([Value] -> Either String Value) -> [Value] -> Either String Value
step Nothing h _ _ = Left ("the state of " ++ idText h ++ " is not available here")
step (Just ref) h clause values = unsafePerformIO $ do
  states <- readIORef ref
  case M.lookup h states of
    Nothing -> pure (Left ("no state for " ++ idText h))
    Just state -> case clause (state : values) of
      Left message -> pure (Left message)
      Right (DataValue _ _ [result, next]) -> do
        writeIORef ref (M.insert h next states)
        pure (Right result)
      Right other -> pure (Left ("a clause of " ++ idText h ++ " gave " ++ show other ++ ", not a pair"))

-- Each operation a law's stateless spec handlers answer, by the clause that
-- answers it.
specResolver :: Program -> Property -> M.Map Id Id
specResolver program p = M.fromList
  [ (operationId (Operation ability op), clause)
  | (ability, choice) <- propertyHandlers p, Just h <- [spec choice], Nothing <- [handlerState h]
  , (op, clause) <- handlerClauses h ]
  where
    handlers = M.fromList [(handlerId h, h) | u <- programUnits program, h <- unitHandlers u]
    spec choice = case choice of
      SpecHandler h -> M.lookup h handlers
      RecordingHandler inner -> spec inner
      ProductionHandler -> Nothing

-- A law's operations its spec handlers answer, as calls of their clauses.
resolvePerforms :: M.Map Id Id -> Property -> Property
resolvePerforms resolver p
  | M.null resolver = p
  | otherwise = p
      { propertyInputs = [q { quantifiedPredicates = map go (quantifiedPredicates q)
                            , quantifiedBounds = [(o, go e) | (o, e) <- quantifiedBounds q] } | q <- propertyInputs p]
      , propertyBody = proposition (propertyBody p)
      , propertyExamples = [x { exampleBindings = [(i, go v) | (i, v) <- exampleBindings x]
                              , exampleExpectations = map proposition (exampleExpectations x) } | x <- propertyExamples p] }
  where
    proposition (Equation ev a b) = Equation ev (go a) (go b)
    proposition (Implication g body) = Implication (go g) (proposition body)
    proposition (Conjunction ps) = Conjunction (map proposition ps)
    go e = case expressionNode e of
      Perform op args | Just clause <- M.lookup (operationId op) resolver ->
        e { expressionNode = ExternalCall clause (if null args then [unit (expressionOrigin e)] else map go args) }
      _ -> mapChildren go e
    unit = Expr (scalarType "Unit") (Constant (SAbsent "Unit"))

-- The definitions some calls reach.
reachableDefinitions :: [Definition] -> [Id] -> [Definition]
reachableDefinitions definitions = go S.empty
  where
    table = M.fromList [(declarationId (definitionDeclaration d), d) | d <- definitions]
    go _ [] = []
    go seen (n : rest)
      | n `S.member` seen = go seen rest
      | Just d <- M.lookup n table = d : go (S.insert n seen) (callees (definitionBody d) ++ rest)
      | otherwise = go (S.insert n seen) rest
-- | The law as a Boolean claim over its inputs: implications become disjunctions.
-- `p = true` is shown as p; other equations are shown as written.
lawClaim :: Property -> Expr
lawClaim = claimWith False

-- | For the prover, a Boolean equation between two predicates becomes their
-- equivalence, which linear arithmetic can decide.
proofClaim :: Property -> Expr
proofClaim = claimWith True

claimWith :: Bool -> Property -> Expr
claimWith forProof p = claim (propertyBody p)
  where
    origin = GeneratedFrom (propertyId p)
    bool = scalarType "Bool"
    claim (Equation evidence a b)
      | expressionType a == bool = case (expressionNode a, expressionNode b) of
          (_, Constant (SBool True)) -> a
          (Constant (SBool True), _) -> b
          (_, Constant (SBool False)) -> negation a
          (Constant (SBool False), _) -> negation b
          _ | forProof -> Expr bool (ShortCircuit Or (Expr bool (ShortCircuit And a b) origin)
                 (Expr bool (ShortCircuit And (negation a) (negation b)) origin)) origin
          _ -> Expr bool (Binary Equal evidence a b) origin
      | otherwise = Expr bool (Binary Equal evidence a b) origin
    claim (Implication guard body) =
      Expr bool (ShortCircuit Or (negation guard) (claim body)) origin
    claim (Conjunction []) = Expr bool (Constant (SBool True)) origin
    claim (Conjunction ps) = foldr1 (\a b -> Expr bool (ShortCircuit And a b) origin) (map claim ps)
    negation e = Expr bool (Unary Not e) origin

-- | A law over definitions only is proved when the totality audit proves it as
-- the result contract of a synthetic definition whose body is the claim and
-- whose preconditions are the input refinements.
proves :: Program -> [Definition] -> Property -> Either String ()
proves program definitions p =
  let proof = Id (idText (propertyId p) ++ "::proof")
      result = Binder (Id (idText proof ++ "::result")) "result" bool
      inputs = map quantifiedBinder (propertyInputs p)
      bool = scalarType "Bool"
      origin = GeneratedFrom (propertyId p)
      claim = inline program definitions (proofClaim p)
      -- The claim is the postcondition itself: the prover must derive it from
      -- the input refinements alone. The body only has to be defined.
      synthetic = Definition (Declaration proof ("proof of " ++ propertyName p)
        (foldr (Arrow . binderType) bool inputs) origin) inputs claim
      contract = Contract proof inputs result (concatMap quantifiedPredicates (propertyInputs p)) [claim] []
      table = M.fromList [(declarationId (definitionDeclaration d), d) | d <- definitions]
      reachable = close S.empty (concatMap callees (definitionBody synthetic : contractPreconditions contract))
      close seen [] = seen
      close seen (n : rest)
        | n `S.member` seen = close seen rest
        | Just d <- M.lookup n table = close (S.insert n seen) (callees (definitionBody d) ++ rest)
        | otherwise = close seen rest
      used = [d | d <- definitions, declarationId (definitionDeclaration d) `S.member` reachable]
      contracts = [c | c <- definitionContracts (programUnits program), contractDeclaration c `S.member` reachable]
  in either (Left . show) (const (Right ()))
       (validateDefinitionContracts (programMachineBits program) (programDataDeclarations program)
         (used ++ [synthetic]) (contracts ++ [contract]))

-- | The prover reasons about calls through their contracts. A definition without
-- preconditions and without recursion has no contract of its own to rely on,
-- so its body is unfolded, a bounded number of times. Definitions with
-- preconditions stay calls, so the audit still checks their arguments.
inline :: Program -> [Definition] -> Expr -> Expr
inline program definitions = go (8 :: Int)
  where
    guarded = S.fromList [contractDeclaration c | c <- definitionContracts (programUnits program), not (null (contractPreconditions c))]
    table = M.fromList [(declarationId (definitionDeclaration d), d) | d <- definitions,
      not (declarationId (definitionDeclaration d) `S.member` guarded), not (recursive d)]
    recursive d = reaches (declarationId (definitionDeclaration d)) S.empty (callees (definitionBody d))
    reaches _ _ [] = False
    reaches target seen (n : rest)
      | n == target = True
      | n `S.member` seen = reaches target seen rest
      | otherwise = reaches target (S.insert n seen)
          (maybe [] (callees . definitionBody) (lookupDefinition n) ++ rest)
    lookupDefinition n = case [d | d <- definitions, declarationId (definitionDeclaration d) == n] of
      d : _ -> Just d
      [] -> Nothing
    go depth e = rebuild (go depth) e $ case expressionNode e of
      ExternalCall n args | depth > 0, Just d <- M.lookup n table, length args == length (definitionArguments d) ->
        Just (go (depth - 1) (substitute (M.fromList (zip (map binderId (definitionArguments d)) (map (go depth) args))) (definitionBody d)))
      _ -> Nothing

-- | Replace locals by expressions. Core identities are unique, so a definition's
-- binders never capture a law's inputs.
substitute :: M.Map Id Expr -> Expr -> Expr
substitute table e = case expressionNode e of
  Local n | Just value <- M.lookup n table -> value
  _ -> rebuildWith (substitute table) e

-- | Apply a replacement at the root, or else rebuild the children with f.
rebuild :: (Expr -> Expr) -> Expr -> Maybe Expr -> Expr
rebuild _ _ (Just replaced) = replaced
rebuild f e Nothing = rebuildWith f e

rebuildWith :: (Expr -> Expr) -> Expr -> Expr
rebuildWith = mapChildren

-- | Native bindings of a generation request.
bindingEvidence :: BindingPlan -> [Obligation]
bindingEvidence plan =
  concat
    [ [ Obligation (dataId declaration) (dataId declaration) "binding" Nothing RuntimeChecked
          "native values are decoded through checked codecs and validated against the declaration"
      ] ++
      [ Obligation (dataId declaration) (dataId declaration) "codec" Nothing Assumed
          "user conversion functions taken on trust; their results are validated"
      | Just _ <- [resolvedCodec binding] ]
    | binding <- resolvedTypes (bindingRepresentations plan), let declaration = resolvedDeclaration binding ] ++
  [ Obligation (resolvedGeneratorType generator) (resolvedGeneratorType generator) "generator" Nothing Assumed
      "custom generator's coverage taken on trust; its values and shrinks are validated"
  | generator <- resolvedGenerators (bindingRepresentations plan) ] ++
  [ Obligation (declarationId declaration) (declarationId declaration) "native-function" Nothing Assumed
      "external native function taken on trust; tested by the laws that call it"
  | (declaration, _) <- bindingFunctions plan ] ++
  [ Obligation (declarationId declaration) (declarationId declaration) "native-function" Nothing Assumed
      "external native method or constructor taken on trust; tested by the laws and models that call it"
  | (declaration, _) <- bindingCalls plan ]

-- The production handler of each built-in ability (LawSpec.Builtins): the
-- runtime's default handler, unless lawspec.json binds another.
defaultHandlerEvidence :: Program -> BindingPlan -> [Obligation]
defaultHandlerEvidence program plan =
  [ if bound then Obligation (unitId u) key "handler" Nothing Assumed
        "bound in lawspec.json: native handler taken on trust; checked by its ability's laws"
      else Obligation (unitId u) key "handler" Nothing DefaultHandler
        (defaultHandlerReason (abilityName a) ++ (if lawful then "; checked by its ability's laws" else ""))
  | u <- programUnits program, idText (unitId u) `elem` defaultedUnits
  , a <- unitAbilities u, abilityOwner a == unitId u, not (isFail (abilityInstance a))
  , let key = Id (abilityKey (abilityInstance a))
        bound = key `elem` map fst (bindingHandlers plan)
        lawful = any (\p -> (abilityName a ++ ": ") `isPrefixOf` propertyName p) (unitProperties u) ]

callees :: Expr -> [Id]
callees e = case expressionNode e of
  ExternalCall n args -> n : concatMap callees args
  Construct _ args -> concatMap callees args
  Match value cases -> callees value ++ concatMap (callees . caseBody) cases
  AllElements value _ body -> callees value ++ callees body
  AllPayloads value predicates -> callees value ++ concatMap (callees . snd) predicates
  Binary _ _ a b -> callees a ++ callees b
  Unary _ a -> callees a
  ShortCircuit _ a b -> callees a ++ callees b
  If c a b -> callees c ++ callees a ++ callees b
  Convert _ _ a -> callees a
  Helper _ args -> concatMap callees args
  _ -> concatMap callees (children e)

showValue :: Value -> String
showValue (ScalarValue s) = prettyScalar s
showValue (DataValue _ tag []) = constructorLabel tag
showValue (DataValue _ tag fields) = "(" ++ unwords (constructorLabel tag : map showValue fields) ++ ")"
showValue (PresenceValue _ Nothing) = "absent"
showValue (PresenceValue _ (Just v)) = showValue v

constructorLabel :: Id -> String
constructorLabel = reverse . takeWhile (/= ':') . reverse . idText
