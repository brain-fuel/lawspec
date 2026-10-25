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
  ( dischargeEvidence, dischargeEvidenceWith, dischargeReporting, refutations, bindingEvidence, defaultHandlerEvidence, lawClaim, callees, showValue
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
import LawSpec.Core.Quantification (lowerWitnessProof, lowerSearchProof)
import LawSpec.Core.QuantifierDomain (finiteQuantifierTerms)
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
        obligation status reason = Obligation (unitId u) (propertyId p) "law" (lawClaim original) status reason
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
        tested status reason = case (harnessSkip harness, harnessKnownFailing harness) of
          (Just why, _) -> obligation Skipped ("skipped by " ++ byHarness ++ ": " ++ why ++ "; otherwise " ++ statusName status ++ ": " ++ reason)
          (_, Just why) -> obligation KnownFailing ("marked known failing by " ++ byHarness ++ ": " ++ why ++
            "; its tests must fail, and a run that passes is reported")
          _ -> obligation status reason
        static status reason = case harnessKnownFailing harness of
          Just _ -> Left [Diagnostic "harness" ("the law " ++ propertyName p ++ " is " ++ statusName status ++
            " by the compiler, so its harness cannot mark it known failing") (Just (propertyLocation p))]
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
          | propertyInputDomain original == UniversalDomain, finiteCases planned == Just [] ->
              if enabled V.Exhaustive || enabled V.Proof then static
                (if enabled V.Exhaustive then ExhaustivelyChecked else Proved)
                "the universal input domain is empty; no cases were evaluated and no witnesses were produced"
              else pure (obligation Incomplete "the universal input domain is empty; no test cases ran, and proof or exhaustive verification was not selected")
          | enabled V.Proof, closed, Right () <- proveScoped definitions registry bits p (plannedProperty planned) -> static Proved
              ("proved statically from its input refinements and the definitions it calls" ++ scopedDomains)
          | enabled V.Exhaustive, closed, not effects, Just tuples <- finiteCases planned -> do
              results <- mapM (\values -> do
                states <- freshStates registry bits (invokeWith Nothing) program original values
                pure (refute (hasLogicalQuantifier (propertyBody original)) registry bits (invokeWith states) (plannedProperty planned) values)) tuples
              let failures = concat [ds | Left ds <- results]
                  incomplete = [d | d <- failures, code d == "witness-search-incomplete"]
                  refuted = [d | d <- failures, code d == "refuted"]
                  errors = [d | d <- failures, code d `notElem` ["witness-search-incomplete", "refuted"]]
              if not (null errors) then Left errors
              -- A counterexample the compiler evaluated refutes the law:
              -- its row says so, and the build fails (refutations).
              else if not (null refuted) then pure (obligation Refuted (intercalate "\n" (map message refuted)))
              else if not (null incomplete) then pure (obligation Incomplete (message (head incomplete)))
              else static ExhaustivelyChecked ("the compiler evaluated " ++ every tuples ++
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
    refute scoped registry bits invoke p values = do
      let env = zip (map (binderId . quantifiedBinder) (propertyInputs p)) values
          at = Just (propertyLocation p)
          shown = intercalate ", " [binderName (quantifiedBinder q) ++ " = " ++ showValue v | (q, v) <- zip (propertyInputs p) values]
          input = if null shown then "" else " for " ++ shown
      case evaluateValueProposition registry bits invoke env (propertyBody p) of
        Right True -> pure ()
        Right False -> Left [Diagnostic "refuted" ("law " ++ propertyName p ++ " is false" ++ input) at]
        Left message | "quantifier-search-incomplete:" `isPrefixOf` message -> Left [Diagnostic "witness-search-incomplete"
          ("law " ++ propertyName p ++ " remains inconclusive" ++ input ++ ": " ++ message) at]
        Left message | scoped -> Left [Diagnostic "verification-incomplete"
          ("scoped search for law " ++ propertyName p ++ " could not complete" ++ input ++ ": " ++ message ++
           "; a failed candidate evaluation does not establish nonexistence") at]
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

-- Whether a law holds a performance budget (LawSpec.Temporal).
budgeted :: Property -> Bool
budgeted p = any measures (propertyExpressions p)
  where
    measures e = case expressionNode e of
      Let b _ _ | isBudgetBinder (binderName b) -> True
      _ -> any measures (children e)
