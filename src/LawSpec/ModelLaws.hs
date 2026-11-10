-- | Laws that hold a property of a model's runs (law n in model m ... is
-- definition: every run holds P), checked over the model's reference: its
-- start, each command's reference definition and precondition, and its
-- state indices. The reference evaluator computes every step, and the
-- explicit-state checker (LawSpec.Core.ModelCheck) explores every reachable
-- state, so a result is the model's, never a native implementation's.
-- ref:DEC-model-checking
module LawSpec.ModelLaws (modelLawEvidence, historyLawEvidence, ModelRun(..), formulaOf, expandFormula, predicateOf, systemOf, StateKey) where

import Control.Monad (forM, unless, when)
import Data.List (intercalate)
import qualified Data.IntSet as IS
import Data.Maybe (fromMaybe, isNothing)
import qualified Data.Map.Strict as M
import LawSpec.Common
import qualified LawSpec.Core as C
import LawSpec.Core.Evidence (Obligation(..), Status(..))
import qualified LawSpec.Core.LawAnalysis as A
import LawSpec.Core.Definitions (Trusted(..), prepareTrustedDefinitions)
import LawSpec.Core.Machine (Machine(..), MachineStart(..), Command(..), admits, shifted)
import LawSpec.Core.ModelCheck
import LawSpec.Core.Value (Value(..), listItems)
import LawSpec.Scalar (Scalar(..), integerBounds, isInteger)
import LawSpec.ModelDomains (dependentRanges, resolveBound)
import LawSpec.ModelReduction (footprints, persistent, readsOfPredicate)
import qualified LawSpec.Model as S

-- | A model law's result.
data ModelRun = ModelRun { runUnit :: C.Id, runLaw :: C.Id, runStatus :: Status, runReason :: String }

-- | The product states the search explores at most, and the argument tuples
-- one command may take.
stateLimit, argumentLimit :: Int
stateLimit = 20000
argumentLimit = 4096

-- | Every model law's evidence, or a diagnostic for one that names no model,
-- command, property or predicate. ran: whether a checking layer is
-- selected.
modelLawEvidence :: Bool -> [S.Unit] -> C.Program -> Either [Diagnostic] [Obligation]
modelLawEvidence ran units program = fmap concat $ forM units $ \u -> do
  let properties = concatMap S.temporalProperties [u' | u' <- units]
      -- Each model's system and reachable graph, built at most once and
      -- shared by every law about it.
      prepared = M.fromList [ (machineName m, prepare m) | cu <- C.programUnits program, C.idText (C.unitId cu) == S.unitName u, m <- C.unitMachines cu ]
      -- When no law about the model assumes fairness or sets a deadline,
      -- and its state has no typestate, it is explored with partial-order
      -- reduction, every law's predicates visible (LawSpec.ModelReduction).
      prepare m = do
        (system, alphabet, stateType) <- systemParts program m
        let lawsHere = [l | l <- S.modelLaws u, S.modelLawModel l == machineName m]
            atomsOf l
              | not (null (S.modelLawFairness l)) = Nothing
              | otherwise = case expandFormula properties (S.modelLawFormula l) of
                  Right (S.TemporalWhenever _ (S.TemporalWithin _ _)) -> Nothing
                  Right (S.TemporalWithin _ _) -> Nothing
                  Right f -> either (const Nothing) (Just . formulaAtoms) (toFormula (predicateOf (S.unitName u) program) f)
                  Left _ -> Nothing
            contracts = [ c | cu <- C.programUnits program, c <- C.unitContracts cu ]
            predicate name = case [ d | cu <- C.programUnits program, d <- C.unitDefinitions cu, C.idText (C.declarationId (C.definitionDeclaration d)) == name ] of
              d : _ -> Right d
              [] -> Left ("no predicate " ++ name)
            reduction = case (mapM atomsOf lawsHere, alphabet) of
              (Just atoms, Just (Right steps)) | not (null lawsHere) -> either (const Nothing) Just $ do
                footprint <- footprints program stateType contracts steps
                predicateReads <- mapM (\a -> predicate a >>= readsOfPredicate program stateType) (concat atoms)
                let visible = foldr (\a b -> IS.union <$> a <*> b) (Just IS.empty) predicateReads
                pure noReduction { reductionPersistent = Just (\_ steps' -> persistent footprint visible steps') }
              _ -> Nothing
        pure (system, explore stateLimit system (fromMaybe noReduction reduction))
  forM (S.modelLaws u) $ \law -> do
    let unitId = C.Id (S.unitName u)
        lawId = C.Id (S.unitName u ++ "::law::" ++ S.modelLawName law)
        at = Just (spanStart (S.modelLawSpan law))
        problem message = Left [Diagnostic "model-law" (S.modelLawName law ++ ": " ++ message) at]
        obligation status reason = Obligation unitId lawId "law" Nothing status reason
    machine <- case [m | cu <- C.programUnits program, C.idText (C.unitId cu) == S.unitName u, m <- C.unitMachines cu, machineName m == S.modelLawModel law] of
      m : _ -> Right m
      [] -> problem ("the unit has no model " ++ S.modelLawModel law)
    let commands = [c | c <- machineCommands machine, not (commandRestart c)]
    forM_' (S.modelLawFairness law) $ \(_, c) ->
      unless (c `elem` map commandName commands) (problem ("assuming fairness for " ++ c ++ ": the model has no command " ++ c))
    expanded <- either problem Right (expandFormula properties (S.modelLawFormula law))
    let atom = predicateOf (S.unitName u) program
    -- A deadline (whenever P, Q within d, or Q within d) is a safety claim
    -- about time; anything else is LTL.
    claim <- either problem Right $ case expanded of
      S.TemporalWhenever p (S.TemporalWithin q d) -> (\p' q' -> Right (Just p', q', d)) <$> predicateFormula atom p <*> predicateFormula atom q
      S.TemporalWithin q d -> (\q' -> Right (Nothing, q', d)) <$> predicateFormula atom q
      _ -> Left <$> toFormula atom expanded
    when (either (const False) (const True) claim && not (S.modelLawEvery law))
      (problem "a deadline holds of every run (every run holds ... within ...)")
    if not ran then pure (obligation NotVerified "no law verification layers selected") else do
      let fairness = [if strong then Strong c else Weak c | (strong, c) <- S.modelLawFairness law]
          hasWait = "wait" `elem` map commandName commands
          checked = do
            (system, graph) <- M.findWithDefault (Left "the model is not prepared") (machineName machine) prepared
            case claim of
              -- Every run holds P: no fair run holds not P. Some run holds P:
              -- a fair run holds P.
              Left formula -> case graph of
                Left outcome -> Right outcome
                Right g -> searchGraph g (systemHolds system) fairness (if S.modelLawEvery law then negation formula else formula)
              Right (trigger, response, d) -> do
                let tick = gcd d hour
                unless hasWait (Left "a deadline needs the model's wait command")
                let timed = deadlineSystem system trigger response d tick
                search stateLimit timed fairness (FUntil FTrue (FAtom lateAtom))
          reducedNote = case M.lookup (machineName machine) prepared of
            Just (Right (_, Right g)) | graphReduced g > 0 ->
              " (a partial-order reduction: " ++ show (graphReduced g) ++ " of them took only independent steps)"
            _ -> ""
          assumed = if null fairness then "" else " under " ++ intercalate " and " [if strong then "strong fairness for " ++ c else "fairness for " ++ c | (strong, c) <- S.modelLawFairness law]
      pure $ case checked of
        Left why | take 11 why == "incomplete:" -> obligation Incomplete (drop 11 why)
                 | otherwise -> obligation Unsupported why
        Right (Bounded n why) -> obligation Incomplete ("no counterexample in the first " ++ show n ++ " states; " ++ why)
        Right (NoRun n)
          | S.modelLawEvery law -> obligation Proved ("every run holds it" ++ assumed ++ ": all " ++ show n ++ " states explored" ++ reducedNote)
          | otherwise -> obligation Refuted ("no run holds it" ++ assumed ++ ": all " ++ show n ++ " states explored" ++ reducedNote)
        Right (Lasso prefix _) | Right (_, _, d) <- claim ->
          obligation Refuted ("a run misses the " ++ duration d ++ " deadline" ++ assumed ++ ": " ++
            intercalate ", " (mergeWaits (filter (/= "stays") prefix)))
        Right (Lasso prefix cycle')
          | S.modelLawEvery law -> obligation Refuted ("a run breaks it" ++ assumed ++ ": " ++ trace prefix cycle')
          | otherwise -> obligation Proved ("a run holds it" ++ assumed ++ ": " ++ trace prefix cycle')
  where
    hour = 3600000000
    -- A state formula of predicates: whenever P, Q within d needs P and Q
    -- about one state.
    -- Its atoms resolved to the predicates' identities.
    predicateFormula atom f = case f of
      S.TemporalAtom name range -> (\resolved -> S.TemporalAtom resolved range) <$> atom name
      S.TemporalNot a -> S.TemporalNot <$> predicateFormula atom a
      S.TemporalAnd a b -> S.TemporalAnd <$> predicateFormula atom a <*> predicateFormula atom b
      S.TemporalOr a b -> S.TemporalOr <$> predicateFormula atom a <*> predicateFormula atom b
      S.TemporalImplies a b -> S.TemporalImplies <$> predicateFormula atom a <*> predicateFormula atom b
      _ -> Left "a deadline relates two conditions on one state: whenever P, Q within d"
    forM_' xs f = mapM_ f xs
    -- place, pay, (capture, refund): the steps, then the steps repeated.
    -- A run that ends stays in its last state.
    trace prefix' cycle'
      | not (null cycle') && all (== "stays") cycle' =
          intercalate ", " (reverse (dropWhile (== "stays") (reverse prefix)) ++ ["then stays"])
      | otherwise = intercalate ", " (prefix ++ ["(" ++ intercalate ", " (mergeWaits cycle') ++ ")" | not (null cycle')])
      where prefix = mergeWaits prefix'

-- | The property as LTL in negation normal form: its words expanded, each
-- atom a Bool function of the model state.
formulaOf :: [S.TemporalProperty] -> String -> C.Program -> S.RunFormula -> Either String Formula
formulaOf properties unit program f = expandFormula properties f >>= toFormula (predicateOf unit program)

-- | The formula with every property reference replaced by its body, and
-- every parameter by its argument: only atoms (predicate names) remain.
expandFormula :: [S.TemporalProperty] -> S.RunFormula -> Either String S.RunFormula
expandFormula properties = go (10 :: Int) M.empty
  where
    go depth bound f = case f of
      S.TemporalAtom name _ -> case M.lookup name bound of
        Just argument -> go depth M.empty argument
        Nothing -> case [p | p <- properties, S.temporalSignature p == [Left name]] of
          p : _ -> expand depth p []
          [] -> Right f
      S.TemporalNot a -> S.TemporalNot <$> go depth bound a
      S.TemporalAnd a b -> S.TemporalAnd <$> go depth bound a <*> go depth bound b
      S.TemporalOr a b -> S.TemporalOr <$> go depth bound a <*> go depth bound b
      S.TemporalImplies a b -> S.TemporalImplies <$> go depth bound a <*> go depth bound b
      S.TemporalAlways a -> S.TemporalAlways <$> go depth bound a
      S.TemporalEventually a -> S.TemporalEventually <$> go depth bound a
      S.TemporalUntil a b -> S.TemporalUntil <$> go depth bound a <*> go depth bound b
      S.TemporalWhenever a b -> S.TemporalWhenever <$> go depth bound a <*> go depth bound b
      S.TemporalNeverBefore a b -> S.TemporalNeverBefore <$> go depth bound a <*> go depth bound b
      S.TemporalWithin a d -> (\a' -> S.TemporalWithin a' d) <$> go depth bound a
      S.TemporalReference items range -> case [ (p, arguments) | p <- properties, Just arguments <- [match range (S.temporalSignature p) items] ] of
        (p, arguments) : _ -> expand depth p [(name, close bound argument) | (name, argument) <- arguments]
        [] -> Left ("no property reads " ++ unwords (map shown items))
      where
        expand d p arguments
          | d <= 0 = Left ("the property " ++ S.temporalName p ++ " refers to itself")
          | otherwise = go (d - 1) (M.fromList arguments) (S.temporalBody p)
    -- An argument means what it meant where it was written: its own
    -- parameters are replaced first.
    close bound f = case f of
      S.TemporalAtom name _ | Just a <- M.lookup name bound -> a
      S.TemporalNot a -> S.TemporalNot (close bound a)
      S.TemporalAnd a b -> S.TemporalAnd (close bound a) (close bound b)
      S.TemporalOr a b -> S.TemporalOr (close bound a) (close bound b)
      S.TemporalImplies a b -> S.TemporalImplies (close bound a) (close bound b)
      S.TemporalAlways a -> S.TemporalAlways (close bound a)
      S.TemporalEventually a -> S.TemporalEventually (close bound a)
      S.TemporalUntil a b -> S.TemporalUntil (close bound a) (close bound b)
      S.TemporalWhenever a b -> S.TemporalWhenever (close bound a) (close bound b)
      S.TemporalNeverBefore a b -> S.TemporalNeverBefore (close bound a) (close bound b)
      S.TemporalWithin a d -> S.TemporalWithin (close bound a) d
      S.TemporalReference items range -> S.TemporalReference [either Left (Right . close bound) i | i <- items] range
      other -> other
    match range signature items = case (signature, items) of
      ([], []) -> Just []
      (Left word : more, Left w : rest) | word == w -> match range more rest
      (Right name : more, item : rest) -> ((name, either (\w -> S.TemporalAtom w range) id item) :) <$> match range more rest
      _ -> Nothing
    shown (Left w) = w
    shown (Right _) = "(...)"

-- | An expanded formula as LTL, each atom resolved to a predicate.
toFormula :: (String -> Either String String) -> S.RunFormula -> Either String Formula
toFormula atom = go
  where
    go f = case f of
      S.TemporalAtom name _ -> FAtom <$> atom name
      S.TemporalNot a -> negation <$> go a
      S.TemporalAnd a b -> FAnd <$> go a <*> go b
      S.TemporalOr a b -> FOr <$> go a <*> go b
      S.TemporalImplies a b -> FOr <$> (negation <$> go a) <*> go b
      S.TemporalAlways a -> FRelease FFalse <$> go a
      S.TemporalEventually a -> FUntil FTrue <$> go a
      S.TemporalUntil a b -> FUntil <$> go a <*> go b
      S.TemporalWhenever p q -> (\p' q' -> FRelease FFalse (FOr (negation p') q')) <$> go p <*> go q
      -- never P before Q: not P, weakly until Q.
      S.TemporalNeverBefore p q -> (\p' q' -> FRelease q' (FOr (negation p') q')) <$> go p <*> go q
      S.TemporalWithin _ _ -> Left "a deadline (within) is checked only as whenever P, Q within d, or Q within d"
      S.TemporalReference _ _ -> Left "a property reference was not expanded"

-- | A predicate of the model state: a checked definition of the unit taking
-- the state alone.
predicateOf :: String -> C.Program -> String -> Either String String
predicateOf unit program name = case [ d | cu <- C.programUnits program, C.idText (C.unitId cu) == unit, d <- C.unitDefinitions cu
                                     , C.declarationName (C.definitionDeclaration d) == name ] of
  d : _ | length (C.definitionArguments d) == 1 -> Right (C.idText (C.declarationId (C.definitionDeclaration d)))
        | otherwise -> Left (name ++ " must be a predicate of the model state alone")
  [] -> Left ("no property or predicate " ++ name ++ " of the model state")

-- | The model's reference as a transition system: a state is a model value
-- and the typestate indices; a step is a command with arguments, allowed by
-- its precondition, its indices and its reference's own refinements,
-- computed by its reference definition. A reference is partial when its
-- parameters are refined: a step outside them is not enabled, as a
-- precondition that does not hold. Argument tuples that do not depend on the
-- indices are enumerated once.
systemOf :: C.Program -> Machine C.Id -> Either String (System StateKey (Value, [Integer]))
systemOf program machine = (\(system, _, _) -> system) <$> systemParts program machine

-- | A step of the model's alphabet: its command, how it is shown, its
-- reference and precondition, and its arguments.
type Step = (String, String, C.Definition, Maybe C.Definition, [Value])

-- | A state's identity in the visited set: its value written out flat, each
-- constructor as a number and each integer as its number in any integer
-- type, then its indices. Comparing constructors' qualified names instead
-- dominated the search, since they share long prefixes. The state's type
-- fixes each constructor's arity, so the flat form is exact; the set keeps
-- every key whole, with no hash compaction, so it never conflates states.
data StateKey = StateKey [KeyAtom] [Integer] deriving (Eq, Ord)

data KeyAtom = KeyTag !Int | KeyName C.Id | KeyScalar Scalar | KeyAbsent | KeyPresent deriving (Eq, Ord)

stateKey :: M.Map C.Id Int -> (Value, [Integer]) -> StateKey
stateKey tags (value, indices) = StateKey (flat value []) indices
  where
    flat v rest = case v of
      ScalarValue (SInteger _ n) -> KeyScalar (SInteger "Integer" n) : rest
      ScalarValue scalar -> KeyScalar scalar : rest
      DataValue _ tag fields -> maybe (KeyName tag) KeyTag (M.lookup tag tags) : foldr flat rest fields
      PresenceValue _ Nothing -> KeyAbsent : rest
      PresenceValue _ (Just inner) -> KeyPresent : flat inner rest

-- | The system, every step it has when its argument tuples do not depend on
-- the indices (Nothing otherwise), and its state type.
systemParts :: C.Program -> Machine C.Id -> Either String (System StateKey (Value, [Integer]), Maybe (Either String [Step]), C.Type)
systemParts program machine = do
  ctx <- A.context program
  let tags = M.fromList (zip [ C.constructorId k | d <- C.programDataDeclarations program, k <- C.dataConstructors d ] [0 ..])
  trusted <- either (Left . concatMap show) Right (prepareTrustedDefinitions program)
  start <- maybe (Left "the model has no start") Right (machineStart machine)
  let definitions = M.fromList [ (C.declarationId (C.definitionDeclaration d), d) | cu <- C.programUnits program, d <- C.unitDefinitions cu ]
      definition name = maybe (Left ("the model's reference " ++ C.idText name ++ " is not a checked definition")) Right (M.lookup name definitions)
      contracts = M.fromListWith (flip (++)) [ (C.contractDeclaration c, [c]) | cu <- C.programUnits program, c <- C.unitContracts cu ]
      -- States are values a checked reference returned and arguments are
      -- enumerated from their types, so calls skip checking them again.
      call d values = trustedCall trusted (C.declarationId (C.definitionDeclaration d)) values
      -- Whether values are inside a definition's refined parameters.
      admitted d values = fmap and $ sequence
        [ trustedEvaluate trusted (zip (map C.binderId (C.contractArguments c)) values) p >>= truth
        | c <- M.findWithDefault [] (C.declarationId (C.definitionDeclaration d)) contracts, p <- C.contractPreconditions c ]
      truth v = case v of
        ScalarValue (SBool b) -> Right b
        _ -> Left "a condition did not evaluate to a Boolean"
      tuples binders = map (map snd) <$> A.enumerateFrom ctx argumentLimit [] [C.Quantifier b [] [] | b <- binders]
      indicesNeeded = machineIndices machine > 0
  startDefinition <- definition (startModel start)
  firstIndices <- case (indicesNeeded, startIndices start) of
    (False, _) -> Right []
    (True, Just is) -> Right is
    (True, Nothing) -> Left "the model's start state indices are not fixed"
  starts <- do
    argumentTuples <- tuples (C.definitionArguments startDefinition)
    forM argumentTuples $ \values -> (\v -> (v, firstIndices)) <$> call startDefinition values
  references <- forM [c | c <- machineCommands machine, not (commandRestart c)] $ \c -> do
    ref <- definition (commandReference c)
    guard' <- traverse definition (commandWhen c)
    let arguments = init (C.definitionArguments ref)
    when (null (C.definitionArguments ref)) (Left ("the reference of " ++ commandName c ++ " takes no model state"))
    ranges <- dependentRanges (C.programDataDeclarations program) (concatMap C.unitContracts (C.programUnits program)) c
    -- Without index-dependent ranges, a command's argument tuples are the
    -- same in every state.
    let fixed = if null ranges then Just (tuplesAt c arguments [] []) else Nothing
    pure (c, ref, guard', arguments, ranges, fixed)
  let steps (state, indices) = fmap concat $ forM references $ \(c, ref, guard', arguments, ranges, fixed) -> do
        allowed <- case guard' of
          Nothing -> Right True
          Just g -> (== ScalarValue (SBool True)) <$> call g [state]
        if not allowed || (indicesNeeded && not (admits c indices)) then Right [] else do
          argumentTuples <- fromMaybe (tuplesAt c arguments ranges indices) fixed
          fmap concat $ forM argumentTuples $ \values -> do
            inside <- admitted ref (values ++ [state])
            if not inside then Right [] else do
              result <- call ref (values ++ [state])
              next <- if commandReturnsUnit c then Right result else case result of
                DataValue _ _ [_, n] -> Right n
                _ -> Left ("the reference of " ++ commandName c ++ " did not give a result and a state")
              let shown = unwords (commandName c : map A.showValue values)
              pure [(commandName c, shown, (next, if indicesNeeded then shifted c indices else indices))]
      predicates = M.fromList [ (C.idText (C.declarationId (C.definitionDeclaration d)), d) | d <- M.elems definitions, length (C.definitionArguments d) == 1 ]
      holds name (state, _) = do
        d <- maybe (Left ("the model's predicate " ++ name ++ " is not a checked definition")) Right (M.lookup name predicates)
        v <- call d [state]
        pure (v == ScalarValue (SBool True))
      alphabet = if indicesNeeded || any (\(_, _, _, _, _, fixed) -> isNothing fixed) references then Nothing else Just $
        fmap concat $ forM references $ \(c, ref, guard', _, _, fixed) -> do
          tuples' <- fromMaybe (Right []) fixed
          pure [ (commandName c, unwords (commandName c : map A.showValue values), ref, guard', values) | values <- tuples' ]
      stateType = case references of
        (_, ref, _, _, _, _) : _ | not (null (C.definitionArguments ref)) -> C.binderType (last (C.definitionArguments ref))
        _ -> C.Constructor "Unit" []
  pure (System starts steps holds (stateKey tags), alphabet, stateType)
  where
    tuplesAt c arguments ranges indices = do
      ctx <- A.context program
      domains <- forM (zip (commandArguments c) arguments) $ \(position, binder) ->
        case (C.binderType binder, lookup position ranges) of
          (C.Constructor name [], Just comparisons) | isInteger name -> do
            values <- mapM (\(op,e) -> (,) op <$> resolveBound indices e) comparisons
            let original = integerBounds (C.programMachineBits program) name
                lowers = [n + if op == C.Greater then 1 else 0 | (op,n) <- values, op `elem` [C.Greater,C.GreaterEqual,C.Equal]] ++ maybe [] (pure . fst) original ++ [0 | name == "BigUInt"]
                uppers = [n - if op == C.Less then 1 else 0 | (op,n) <- values, op `elem` [C.Less,C.LessEqual,C.Equal]] ++ maybe [] (pure . snd) original
            if null lowers || null uppers then Left "not finite: model command argument has no finite bounds" else do
              let lo = maximum lowers; hi = minimum uppers
              if hi - lo + 1 > toInteger argumentLimit then Left "incomplete: model command argument domain exceeds enumeration limit"
                else Right [ScalarValue (SInteger name n) | n <- [lo..hi], all (\(op,k) -> op /= C.NotEqual || n /= k) values]
          _ -> map (snd . head) <$> A.enumerateFrom ctx argumentLimit [] [C.Quantifier binder [] []]
      let productSize = product (map (toInteger . length) domains)
      if productSize > toInteger argumentLimit then Left "incomplete: model command argument tuples exceed enumeration limit"
        else Right (sequence domains)

-- | The predicate a deadline's search looks for: a deadline passed.
lateAtom :: String
lateAtom = "late"

-- | The model with time: each step either is a command, which takes no
-- time, or advances one tick through the model's explicit wait command. A timer runs from the first state
-- where the trigger holds (or the start, for Q within d) until one where
-- the response holds; once it passes d, the run is late. Time is whole
-- microseconds, and a deadline is met at exactly d.
deadlineSystem :: System k (Value, [Integer]) -> Maybe S.RunFormula -> S.RunFormula -> Integer -> Integer
  -> System (k, Maybe Integer, Bool) ((Value, [Integer]), Maybe Integer, Bool)
deadlineSystem base trigger response d tick = System starts steps holds key
  where
    truth f s = case f of
      S.TemporalAtom name _ -> systemHolds base name s
      S.TemporalNot a -> not <$> truth a s
      S.TemporalAnd a b -> (&&) <$> truth a s <*> truth b s
      S.TemporalOr a b -> (||) <$> truth a s <*> truth b s
      S.TemporalImplies a b -> (\x y -> not x || y) <$> truth a s <*> truth b s
      _ -> Left "a deadline relates conditions on one state"
    starts = [ (s, start s, False) | s <- systemInitial base ]
    start s = case (trigger, truth response s) of
      (Nothing, Right False) -> Just 0
      (Just p, Right False) | Right True <- truth p s -> Just 0
      _ -> Nothing
    -- After a step into s, with the timer as it was.
    settle s timer = case truth response s of
      Right True -> Right Nothing
      Right False -> case (timer, trigger) of
        (Nothing, Just p) -> (\fired -> if fired then Just 0 else Nothing) <$> truth p s
        _ -> Right timer
      Left why -> Left why
    steps (_, _, True) = Right []
    steps (s, timer, False) = do
      moves <- systemSteps base s
      commands <- mapM (\(c, shown, s') ->
        if c == "wait" then passing s' timer else do
          timer' <- settle s' timer
          pure (c, shown, (s', timer', False))) moves
      pure commands
    passing s timer = case timer of
      Just t | t + tick > d -> Right ("wait", "wait " ++ duration tick, (s, Just (t + tick), True))
      _ -> do
        timer' <- settle s ((+ tick) <$> timer)
        Right ("wait", "wait " ++ duration tick, (s, timer', False))
    holds name (s, _, late)
      | name == lateAtom = Right late
      | otherwise = systemHolds base name s
    key (s, timer, late) = (systemKey base s, timer, late)

-- | Whole microseconds in the largest unit that divides them.
duration :: Integer -> String
duration us = case [ (us `div` size, unit) | (size, unit) <- units, us `mod` size == 0 ] of
  (n, unit) : _ -> show n ++ unit
  [] -> show us ++ "us"
  where units = [(3600000000, "h"), (60000000, "min"), (1000000, "s"), (1000, "ms"), (1, "us")]

-- | Consecutive waits as one: wait 1h, wait 1h becomes wait 2h.
mergeWaits :: [String] -> [String]
mergeWaits steps = go steps
  where
    go xs = case xs of
      w : rest | Just a <- waited w ->
        let (more, after) = span (maybe False (const True) . waited) rest
            total = a + sum [b | Just b <- map waited more]
        in ("wait " ++ duration total) : go after
      x : rest -> x : go rest
      [] -> []
    waited w = case words w of
      ["wait", amount] -> parseDuration amount
      _ -> Nothing
    parseDuration text = let (digits, unit) = span (`elem` ("0123456789" :: String)) text
                         in if null digits then Nothing else (* read digits) <$> lookup unit
                              [("h", 3600000000), ("min", 60000000), ("s", 1000000), ("ms", 1000), ("us", 1)]

-- | Laws about an observed history: its entries, in order, from a checked
-- definition taking Unit. A complete history ends there; an open one may go
-- on, so a law about it holds, breaks, or is pending. A deadline (whenever
-- P, Q within d) reads each entry's time from its field at, and breaks as
-- soon as an entry is observed past it. ref:DEC-history-checking
historyLawEvidence :: Bool -> [S.Unit] -> C.Program -> Either [Diagnostic] [Obligation]
historyLawEvidence ran units program = fmap concat $ forM units $ \u -> do
  let properties = concatMap S.temporalProperties units
  forM (S.historyLaws u) $ \law -> do
    let unitId = C.Id (S.unitName u)
        lawId = C.Id (S.unitName u ++ "::law::" ++ S.historyLawName law)
        at = Just (spanStart (S.historySpan law))
        problem message = Left [Diagnostic "history-law" (S.historyLawName law ++ ": " ++ message) at]
        obligation status reason = Obligation unitId lawId "law" Nothing status reason
        atom = predicateOf (S.unitName u) program
        what = if S.historyComplete law then "the complete history" else "the history so far"
    source <- case [ d | cu <- C.programUnits program, C.idText (C.unitId cu) == S.unitName u, d <- C.unitDefinitions cu
                       , C.declarationName (C.definitionDeclaration d) == S.historySource law ] of
      d : _ | [_] <- C.definitionArguments d -> Right d
      _ -> problem ("the unit has no checked definition " ++ S.historySource law ++ " taking Unit")
    expanded <- either problem Right (expandFormula properties (S.historyFormula law))
    if not ran then pure (obligation NotVerified "no law verification layers selected") else do
      let judged = do
            ctx <- A.context program
            let evaluate d values = A.contextEvaluate ctx (zip (map C.binderId (C.definitionArguments d)) values)
                  (C.Expr (snd (C.functionType (C.declarationType (C.definitionDeclaration d))))
                     (C.ExternalCall (C.declarationId (C.definitionDeclaration d))
                        [C.Expr (C.binderType b) (C.Local (C.binderId b)) (C.GeneratedFrom (C.Id "history")) | b <- C.definitionArguments d])
                     (C.GeneratedFrom (C.Id "history")))
                definitionOf name = case [d | cu <- C.programUnits program, d <- C.unitDefinitions cu, C.idText (C.declarationId (C.definitionDeclaration d)) == name] of
                  d : _ -> Right d
                  [] -> Left ("no predicate " ++ name)
            entries <- evaluate source [ScalarValue (SAbsent "Unit")] >>= listItems
            let n = length entries
                holds name i = do
                  d <- definitionOf name
                  (== ScalarValue (SBool True)) <$> evaluate d [entries !! i]
                truth f i = case f of
                  S.TemporalAtom name _ -> atom name >>= \resolved -> holds resolved i
                  S.TemporalNot a -> not <$> truth a i
                  S.TemporalAnd a b -> (&&) <$> truth a i <*> truth b i
                  S.TemporalOr a b -> (||) <$> truth a i <*> truth b i
                  S.TemporalImplies a b -> (\x y -> not x || y) <$> truth a i <*> truth b i
                  _ -> Left "a deadline relates conditions on one entry"
            case expanded of
              S.TemporalWhenever p (S.TemporalWithin q d) -> do
                times <- mapM (timeOf program) entries
                unless (and (zipWith (<=) times (drop 1 times)))
                  (Left "a history's observation times must be nondecreasing")
                verdict <- deadline (truth p) (truth q) d times
                pure (verdict, n, case verdict of
                  Breaks i -> Just (" when the " ++ duration d ++ " deadline passes, observed at " ++ duration (times !! i))
                  _ -> Nothing)
              _ -> do
                formula <- toFormula atom expanded
                verdict <- judge (S.historyComplete law) formula n holds
                -- An open history's pending law: does it hold as far as it goes?
                sofar <- if verdict == Open then (== Holds) <$> judge True formula n holds else pure False
                pure (verdict, n, if verdict == Open then Just (if sofar then "it holds so far, and what comes next may still break it"
                                                                 else "it does not hold yet, and what comes next may make it hold") else Nothing)
          deadline p q d times = go 0 Nothing
            where
              go i pending
                | i >= length times = Right (case pending of
                    Just _ | S.historyComplete law -> Breaks (length times - 1)
                    Just _ -> Open
                    Nothing | S.historyComplete law -> Holds
                    _ -> Open)
                | otherwise = do
                    answered <- q i
                    triggered <- p i
                    case pending of
                      Just t0 | times !! i - t0 > d -> Right (Breaks i)
                      _ -> go (i + 1) (if answered then Nothing else case pending of
                             Just t0 -> Just t0
                             Nothing -> if triggered then Just (times !! i) else Nothing)
      pure $ case judged of
        Left why -> obligation Unsupported why
        Right (Holds, n, _)
          | S.historyComplete law -> obligation Proved ("the complete history holds it: all " ++ show n ++ " entries checked")
          | otherwise -> obligation Proved ("the history so far holds it, whatever comes next: " ++ show n ++ " entries")
        Right (Breaks i, n, detail) -> obligation Refuted (what ++ " breaks it at entry " ++ show (i + 1) ++ " of " ++ show n ++ maybe "" ("," ++) detail)
        Right (Open, n, detail) -> obligation Pending ("pending: the " ++ show n ++ " entries so far do not decide it; " ++ maybe "" id detail)

-- | An entry's observed time, in microseconds: its field at, a Duration or
-- an integer.
timeOf :: C.Program -> Value -> Either String Integer
timeOf program entry = case entry of
  DataValue (C.Constructor name _) tag fields
    | d : _ <- [d | d <- C.programDataDeclarations program, C.idText (C.dataId d) == name]
    , c : _ <- [c | c <- C.dataConstructors d, C.constructorId c == tag]
    , Just i <- lookup "at" (zip (map C.binderName (C.constructorFields c)) [0 ..])
    , i < length fields -> micros (fields !! i)
  _ -> Left "a deadline needs each entry's time, in a field named at"
  where
    micros v = case v of
      ScalarValue (SInteger _ n) -> Right n
      DataValue _ _ [inner] -> micros inner
      _ -> Left "an entry's at is not a Duration"
