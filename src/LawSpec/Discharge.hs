{-# LANGUAGE FlexibleContexts #-}
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
module LawSpec.Discharge
  ( dischargeEvidence, dischargeEvidenceWith, dischargeReporting, refutations, bindingEvidence, defaultHandlerEvidence, lawClaim, callees, showValue, budgeted
  ) where

import Control.Monad (forM, unless)
import Control.Monad.State.Strict (StateT, evalStateT, get, put, modify, lift)
import Control.Monad.Except (throwError)
import LawSpec.Naming (displayLabel)
import Data.List (intercalate, isPrefixOf, isInfixOf)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import LawSpec.Common
import LawSpec.Core
import LawSpec.Core.DefinitionContracts (definitionContracts)
import LawSpec.Core.Definitions (prepareHookedDefinitionsM)
import LawSpec.Core.Eval (evaluateValueM, evaluateValuePropositionM)
import LawSpec.Core.Quantification (lowerWitnessProof, lowerSearchProof)
import LawSpec.Core.QuantifierDomain (finiteQuantifierTerms)
import LawSpec.Core.Evidence
import LawSpec.Core.Total (validateDefinitionContracts)
import LawSpec.Core.Types (makeRegistry, TypeRegistry)
import LawSpec.Core.Value (Value(..))
import LawSpec.NativeBinding
import LawSpec.NativeRequest (BindingPlan(..))
import LawSpec.Scalar (Scalar(..), prettyScalar)
import LawSpec.Builtins (defaultedUnits, defaultHandlerReason)
import LawSpec.Temporal (isBudgetBinder)
import qualified LawSpec.Core.Verification as V
import LawSpec.Testing (finiteCases, PlannedProperty(..), lawPlanner, finiteValuesWithRegistry, boundedLawSearch)

-- | Laws first, then contracts, constructions and adapters. A law over checked
-- definitions whose finite domain contains a counterexample is refuted here.
dischargeEvidence :: Program -> Either [Diagnostic] [Obligation]
dischargeEvidence program = dischargeSelected Nothing program >>= failRefuted program
dischargeEvidenceWith :: V.Verification -> Program -> Either [Diagnostic] [Obligation]
dischargeEvidenceWith config program = dischargeSelected (Just config) program >>= failRefuted program

-- | Evidence with refuted laws kept as rows, for reports that show them
-- beside the rest; refutations gives the diagnostics that fail the build.
dischargeReporting :: Maybe V.Verification -> Program -> Either [Diagnostic] [Obligation]
dischargeReporting = dischargeSelected

-- | A refuted law fails the build: one refuted diagnostic per failing input,
-- at the law.
refutations :: Program -> [Obligation] -> [Diagnostic]
refutations program evidence =
  [ Diagnostic "refuted" line (lookup (obligationDeclaration item) locations)
  | item <- evidence, obligationStatus item == Refuted, line <- lines (obligationReason item) ]
  where locations = [(propertyId p, propertyLocation p) | u <- programUnits program, p <- unitProperties u]

failRefuted :: Program -> [Obligation] -> Either [Diagnostic] [Obligation]
failRefuted program evidence = case refutations program evidence of
  [] -> Right evidence
  ds -> Left ds
dischargeSelected :: Maybe V.Verification -> Program -> Either [Diagnostic] [Obligation]
dischargeSelected selection program = do
  metered <- prepareHookedDefinitionsM evaluationStep program
  let evaluation = maybe V.defaultEvaluation V.evaluation selection
      identities = [idText (unitId u) ++ "::" ++ displayLabel (propertyName p) | u <- programUnits program, p <- unitProperties u]
      unknown = filter (`notElem` identities) (V.deferLaws evaluation)
  unless (null unknown) (Left [Diagnostic "verification" ("unknown deferred law: " ++ identity) Nothing | identity <- unknown])
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
        obligation status reason = Obligation (unitId u) (propertyId p) "law" (lawClaim original) status reason
        called = S.fromList (concatMap callees (propertyExpressions p))
        adapters = S.toList (S.difference called definitionIds)
        reached = reachableDefinitions definitions (S.toList called)
        effects = any (effectful (\operation -> operation `M.member` stateful || operation `M.member` resolver))
          (propertyExpressions p ++ map definitionBody reached) ||
          any (\op -> M.notMember (operationId op) resolver && M.notMember (operationId op) stateful)
            (concatMap (performed . definitionBody) reached ++ concatMap performed (propertyExpressions p))
        natives = [ability | (ability, choice) <- propertyHandlers p, not (isFail ability), production choice]
        relying adapters' = relyingOn (adapters' ++ [Id ("the native " ++ abilityKey a ++ " handler") | a <- natives])
        -- A law with resources gets them when it runs, never from the compiler.
        closed = null adapters && null (propertyResources p)
        scopedDomains
          | not (null (harnessSearches (propertyHarness p))) =
              "; scoped checking uses selected bounded strategies, configured witnesses and complete finite fallback; a bounded miss never proves nonexistence"
          | not (null (harnessWitnesses (propertyHarness p))) =
              "; scoped checking uses configured constructive witnesses and any complete finite fallback; candidate failure alone supplies no nonexistence evidence"
          | hasLogicalQuantifier (propertyBody p) = "; scoped checking uses complete finite covers or verified bounded candidates; a bounded miss never proves nonexistence"
          | otherwise = ""
        count n noun = show n ++ " " ++ noun ++ (if n == 1 then "" else "s")
        settings = propertyGeneration p
        every [_] = "its only case"
        every tuples = "all " ++ show (length tuples) ++ " inputs"
        harness = propertyHarness original
        byHarness = maybe "its harness" ("the harness " ++) (harnessUnit harness)
        -- The harness plane decides whether the tests run, never what a
        -- static proof or the compiler's own check established.
        tested status reason = case (harnessSkip harness, harnessKnownDiscrepancy harness) of
          (Just why, _) -> obligation Skipped ("skipped by " ++ byHarness ++ ": " ++ why ++ "; otherwise " ++ statusName status ++ ": " ++ reason)
          (_, Just why) -> obligation KnownDiscrepancy ("marked known discrepancy by " ++ byHarness ++ ": " ++ why ++
            "; its tests must reproduce the discrepancy; a passing run requires human review of the specification and implementation, either or both of which may need correction")
          _ -> obligation status reason
        static status reason = case harnessKnownDiscrepancy harness of
          Just _ -> Left [Diagnostic "harness" ("the law " ++ propertyName p ++ " is " ++ statusName status ++
            " by the compiler, so its harness cannot mark it as a known discrepancy") (Just (propertyLocation p))]
          Nothing -> pure (obligation status (reason ++ maybe "" (const "; its harness skips its tests") (harnessSkip harness)))
    let enabled layer = maybe True (`V.selected` layer) selection
        pending status reason = pure (tested (if selection == Nothing then status else Planned) reason)
    if not (any enabled [V.Proof,V.Exhaustive,V.Property,V.Examples,V.Runtime,V.Analysis])
      then pure (obligation NotVerified "no law verification layers selected; intrinsic definition checks still apply")
      else case plan p of
        Left message -> pure (tested (if selection == Nothing then Assumed else
          if "quantifier-search-incomplete:" `isPrefixOf` message then Incomplete else Unsupported)
          ((if selection == Nothing then "not executable, so taken on trust: " else "verification cannot execute this domain: ") ++ message))
        Right _ | budgeted p -> pending Measured
              (if selection == Nothing then "a performance budget: the generated tests time it on the real clock, so it is measured, never proved"
               else "a performance budget: the generated tests will time it on the real clock; no measurement has completed")
        Right planned
          | idText (unitId u) ++ "::" ++ displayLabel (propertyName original) `elem` V.deferLaws evaluation ->
              pure (obligation (if continuation enabled planned then Planned else Incomplete)
                "optional compiler evaluation explicitly deferred; intrinsic definition checks passed; no compiler law result")
          | propertyInputDomain original == UniversalDomain, finiteCases planned == Just [] ->
              if enabled V.Exhaustive || enabled V.Proof then static
                (if enabled V.Exhaustive then ExhaustivelyChecked else Proved)
                "the universal input domain is empty; no cases were evaluated and no witnesses were produced"
              else pure (obligation Incomplete "the universal input domain is empty; no test cases ran, and proof or exhaustive verification was not selected")
          | enabled V.Proof, closed, Right () <- proveScoped definitions registry bits p (plannedProperty planned) -> static Proved
              ("proved statically from its input refinements and the definitions it calls" ++ scopedDomains)
          | enabled V.Exhaustive, closed, not effects, Just tuples <- finiteCases planned -> do
              let checkCases [] = pure Nothing
                  checkCases (values : rest) = do
                    accepted <- evaluateCase metered registry bits program original (plannedProperty planned) values
                    if accepted then checkCases rest else pure (Just values)
                  checked = evalStateT (checkCases tuples)
                    (V.maxSteps evaluation, M.empty)
              case checked of
                Left message | "evaluation-exhausted:" `isInfixOf` message ->
                  pure (obligation (if continuation enabled planned then Planned else Incomplete)
                    ("optional compiler evaluation exhausted its " ++ show (V.maxSteps evaluation) ++ " logical steps; no completed compiler law result"))
                Left message | "quantifier-search-incomplete:" `isInfixOf` message -> pure (obligation Incomplete message)
                Left message | hasLogicalQuantifier (propertyBody original) ->
                  Left [Diagnostic "verification-incomplete"
                    ("scoped search could not complete: " ++ message ++ "; a failed candidate evaluation does not establish nonexistence")
                    (Just (propertyLocation original))]
                Left message -> pure (obligation Refuted ("law " ++ propertyName p ++ " is undefined: " ++ message))
                Right (Just values) -> pure (obligation Refuted ("law " ++ propertyName p ++ " is false" ++
                  (if null values then "" else " for " ++ intercalate ", "
                    [binderName (quantifiedBinder q) ++ " = " ++ showValue value | (q,value) <- zip (propertyInputs p) values])))
                Right Nothing -> static ExhaustivelyChecked ("the compiler evaluated " ++ every tuples ++
                  "; the generated tests check " ++ (if length tuples == 1 then "it" else "them") ++ " again natively" ++ scopedDomains)
          | enabled V.Exhaustive, Just tuples <- finiteCases planned -> pending ExhaustivelyChecked
              ("the generated tests check " ++ every tuples ++ relying adapters ++ scopedDomains)
          | enabled V.Property -> pending PropertyTested
              ("the generated tests check " ++ count (cases settings) "generated case" ++ ", " ++
               count (length (boundaryCases planned)) "boundary case" ++ " and " ++
               count (length (propertyExamples p)) "example" ++ relying adapters)
          | enabled V.Examples, null (propertyExamples p),
            not (any enabled [V.Proof,V.Exhaustive,V.Property,V.Runtime,V.Analysis]) ->
              pure (obligation NotVerified "no authored examples are selected for this law; no law checks ran")
          | enabled V.Examples -> pending PropertyTested
              ("the generated tests will check " ++ count (length (propertyExamples p)) "example" ++ relying adapters)
          | otherwise -> pure (obligation Incomplete "the selected analyses have not established this law; no completed proof or exhaustive result")
  let intrinsic item = case selection of
        Nothing -> item
        Just config | obligationStage item `elem`
          ["model","linearizable","sequentially consistent","causally consistent","eventually consistent","restart","scenario","supervision"] ->
            item { obligationStatus = if V.selected config V.Model then Planned else NotVerified
                 , obligationReason = if V.selected config V.Model then "native model checks are planned; no execution evidence supplied"
                     else "model verification was not selected; intrinsic typing and scenario checks still apply" }
        _ -> item
  pure (laws ++ map intrinsic (programEvidence program))
  where
    proveScoped definitions registry bits original planned
      | propertyInputDomain original == UniversalDomain && hasLogicalQuantifier (propertyBody original) = do
          let settings = propertyGeneration original
              limit = exhaustiveLimit settings
              budget = max 1 (min (cases settings) (maxAttempts settings))
              sizes n | n >= toInteger budget = [budget]
                      | otherwise = fromInteger n : sizes (min (toInteger budget) (2*n))
              -- Small constructive certificates avoid spending the prover's
              -- branch budget on unused alternatives. Increasing prefixes
              -- can still combine different witnesses for different inputs.
              attempt _ [] = Left "the constructive candidates did not establish a proof within the shared prover's limits"
              attempt seen (size:rest) = do
                claim <- lowerSearchProof (finiteQuantifierTerms bits limit (finiteValuesWithRegistry registry bits limit))
                  (\q body -> take size <$> boundedLawSearch registry bits original q body)
                  limit (maxAttempts settings) (propertyId original)
                  (harnessWitnesses (propertyHarness original)) (propertyBody original)
                if claim `elem` seen then attempt seen rest else
                  case proves program definitions original { propertyBody = claim } of
                    Right () -> Right ()
                    Left _ -> attempt (claim:seen) rest
          attempt [] (sizes 1)
      | null (harnessWitnesses (propertyHarness original)) = proves program definitions planned
      | otherwise = do
          let limit = exhaustiveLimit (propertyGeneration original)
          claim <- lowerWitnessProof (finiteQuantifierTerms bits limit (finiteValuesWithRegistry registry bits limit)) limit (propertyId original)
            (harnessWitnesses (propertyHarness original)) (propertyBody original)
          proves program definitions original { propertyBody = claim }
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
-- Logical work is deterministic and local to one law, across all its inputs.
-- Each expression visit and each value-validation node consumes one step.
-- Admission uses the unmetered evaluator and is never bypassed by this budget.
type EvaluationRun = StateT (Integer, M.Map Id Value) (Either String)

evaluationStep :: EvaluationRun ()
evaluationStep = do
  (remaining, states) <- get
  if remaining <= 0 then throwError "evaluation-exhausted: logical step limit"
    else put (remaining - 1, states)

continuation :: (V.Layer -> Bool) -> PlannedProperty -> Bool
-- A complete empty cover emits no native case. Selecting a layer alone does
-- not make an executable continuation available (ref:DEC-s1j-evaluation-budget).
continuation enabled planned =
  (enabled V.Property && (finiteCases planned /= Just [] || not (null (boundaryCases planned)))) ||
  (enabled V.Exhaustive && maybe False (not . null) (finiteCases planned)) ||
  (enabled V.Examples && not (null (propertyExamples (plannedProperty planned))))

evaluateCase :: (((Id -> [Value] -> EvaluationRun Value) -> Id -> Maybe ([Value] -> EvaluationRun Value)) -> Id -> [Value] -> EvaluationRun Value)
  -> TypeRegistry -> Int -> Program -> Property -> Property -> [Value] -> EvaluationRun Bool
evaluateCase metered registry bits program original planned values = do
  modify (\(fuel, _) -> (fuel, M.empty))
  let stateless = specResolver program original
      stateful = statefulResolver program original
      hook invoke identity = case M.lookup identity stateless of
        Just clause -> Just (\args -> invoke clause (if null args then [ScalarValue (SAbsent "Unit")] else args))
        Nothing -> case M.lookup identity stateful of
          Nothing -> Nothing
          Just (handler, clause) -> Just $ \args -> do
            (_, states) <- get
            state <- maybe (throwError "handler state unavailable") pure (M.lookup handler states)
            result <- invoke clause (state : args)
            case result of
              DataValue _ _ [value, next] -> modify (\(fuel, table) -> (fuel, M.insert handler next table)) >> pure value
              _ -> throwError "stateful handler did not return a pair"
      invoke = metered hook
  mapM_ (\handler -> case handlerState handler of
    Just (_, start) -> do
      value <- evaluateValueM evaluationStep registry bits invoke [] start
      modify (\(fuel, states) -> (fuel, M.insert (handlerId handler) value states))
    Nothing -> pure ()) [handler | (_, choice) <- propertyHandlers original, Just handler <- [specHandlerFor program choice]]
  evaluateValuePropositionM evaluationStep registry bits invoke
    (zip (map (binderId . quantifiedBinder) (propertyInputs planned)) values) (propertyBody planned)

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
      , propertyParameters = [q { quantifiedPredicates = map go (quantifiedPredicates q)
                            , quantifiedBounds = [(o, go e) | (o, e) <- quantifiedBounds q] } | q <- propertyParameters p]
      , propertyBody = proposition (propertyBody p)
      , propertyExamples = [x { exampleBindings = [(i, go v) | (i, v) <- exampleBindings x]
                              , exampleExpectations = map proposition (exampleExpectations x) } | x <- propertyExamples p] }
  where
    proposition = mapPropositionExpressions go
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
lawClaim :: Property -> Maybe Expr
lawClaim = claimWith False

-- The scalar proof engine receives only executable Boolean claims. Scoped
-- propositions have no scalar stand-in; their authoritative wire view remains
-- the proposition, until a complete search plan can lower it.
proofClaim :: Property -> Maybe Expr
proofClaim = claimWith True

claimWith :: Bool -> Property -> Maybe Expr
claimWith forProof p = claim (propertyBody p)
  where
    origin = GeneratedFrom (propertyId p)
    bool = scalarType "Bool"
    claim (Equation evidence a b) = Just $
      if expressionType a == bool then case (expressionNode a, expressionNode b) of
        (_, Constant (SBool True)) -> a
        (Constant (SBool True), _) -> b
        (_, Constant (SBool False)) -> negation a
        (Constant (SBool False), _) -> negation b
        _ | forProof -> Expr bool (ShortCircuit Or (Expr bool (ShortCircuit And a b) origin)
               (Expr bool (ShortCircuit And (negation a) (negation b)) origin)) origin
        _ -> Expr bool (Binary Equal evidence a b) origin
      else Expr bool (Binary Equal evidence a b) origin
    claim (Implication guard body) =
      (\value -> Expr bool (ShortCircuit Or (negation guard) value) origin) <$> claim body
    claim (Conjunction []) = Just (Expr bool (Constant (SBool True)) origin)
    claim (Conjunction bodies) = foldr1 (\a b -> Expr bool (ShortCircuit And a b) origin) <$> mapM claim bodies
    claim (Negation body) = negation <$> claim body
    claim (Quantified _ _ _) = Nothing
    negation e = Expr bool (Unary Not e) origin

-- | A law over definitions only is proved when the totality audit proves it as
-- the result contract of a synthetic definition whose body is the claim and
-- whose preconditions are the input refinements.
proves :: Program -> [Definition] -> Property -> Either String ()
proves program definitions p = do
  scalarClaim <- maybe (Left "a scoped proposition needs a complete search or constructive proof") Right (proofClaim p)
  let proof = Id (idText (propertyId p) ++ "::proof")
      result = Binder (Id (idText proof ++ "::result")) "result" bool
      quantifiers = propertyParameters p ++ propertyInputs p
      inputs = map quantifiedBinder quantifiers
      bool = scalarType "Bool"
      origin = GeneratedFrom (propertyId p)
      claim = inline program definitions scalarClaim
      -- The claim is the postcondition itself: the prover must derive it from
      -- the input refinements alone. The body only has to be defined.
      synthetic = Definition (Declaration proof ("proof of " ++ propertyName p)
        (foldr (Arrow . binderType) bool inputs) origin) inputs claim
      contract = Contract proof inputs result (concatMap quantifiedPredicates quantifiers) [claim] []
      table = M.fromList [(declarationId (definitionDeclaration d), d) | d <- definitions]
      reachable = close S.empty (concatMap callees (definitionBody synthetic : contractPreconditions contract))
      close seen [] = seen
      close seen (n : rest)
        | n `S.member` seen = close seen rest
        | Just d <- M.lookup n table = close (S.insert n seen) (callees (definitionBody d) ++ rest)
        | otherwise = close seen rest
      used = [d | d <- definitions, declarationId (definitionDeclaration d) `S.member` reachable]
      contracts = [c | c <- definitionContracts (programUnits program), contractDeclaration c `S.member` reachable]
  either (Left . show) (const (Right ()))
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
    -- Whether a definition unfolds is decided for the ones a claim calls, not
    -- for every definition of the program.
    unfoldable n = case lookupDefinition n of
      Just d | not (n `S.member` guarded), not (recursive d) -> Just d
      _ -> Nothing
    recursive d = reaches (declarationId (definitionDeclaration d)) S.empty (callees (definitionBody d))
    reaches _ _ [] = False
    reaches target seen (n : rest)
      | n == target = True
      | n `S.member` seen = reaches target seen rest
      | otherwise = reaches target (S.insert n seen)
          (maybe [] (callees . definitionBody) (lookupDefinition n) ++ rest)
    byId = M.fromListWith (\_ first -> first) [(declarationId (definitionDeclaration d), d) | d <- definitions]
    lookupDefinition n = M.lookup n byId
    go depth e = rebuild (go depth) e $ case expressionNode e of
      ExternalCall n args | depth > 0, Just d <- unfoldable n, length args == length (definitionArguments d) ->
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
-- runtime's default handler, unless lawspec.edn binds another.
defaultHandlerEvidence :: Program -> BindingPlan -> [Obligation]
defaultHandlerEvidence program plan =
  [ if bound then Obligation (unitId u) key "handler" Nothing Assumed
        "bound in lawspec.edn: native handler taken on trust; checked by its ability's laws"
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
  MapElements value _ body -> callees value ++ callees body
  FilterElements value _ body -> callees value ++ callees body
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

-- Whether a law holds a performance budget (LawSpec.Temporal).
budgeted :: Property -> Bool
budgeted p = any measures (propertyExpressions p)
  where
    measures e = case expressionNode e of
      Let b _ _ | isBudgetBinder (binderName b) -> True
      _ -> any measures (children e)
