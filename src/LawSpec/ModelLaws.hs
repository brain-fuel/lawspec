-- | Laws that hold a property of a model's runs (law n in model m ... is
-- definition: every run holds P), checked over the model's reference: its
-- start, each command's reference definition and precondition, and its
-- state indices. The reference evaluator computes every step, and the
-- explicit-state checker (LawSpec.Core.ModelCheck) explores every reachable
-- state, so a result is the model's, never a native implementation's.
-- ref:DEC-model-checking
module LawSpec.ModelLaws (modelLawEvidence, ModelRun(..), formulaOf) where

import Control.Monad (forM, unless, when)
import Data.List (intercalate)
import qualified Data.Map.Strict as M
import LawSpec.Common
import qualified LawSpec.Core as C
import LawSpec.Core.Evidence (Obligation(..), Status(..))
import qualified LawSpec.Core.LawAnalysis as A
import LawSpec.Core.Machine (Machine(..), MachineStart(..), Command(..), admits, shifted)
import LawSpec.Core.ModelCheck
import LawSpec.Core.Value (Value(..))
import LawSpec.Scalar (Scalar(..))
import qualified LawSpec.Model as S

-- | A model law's result.
data ModelRun = ModelRun { runUnit :: C.Id, runLaw :: C.Id, runStatus :: Status, runReason :: String }

-- | The product states the search explores at most, and the argument tuples
-- one command may take.
stateLimit, argumentLimit :: Int
stateLimit = 100000
argumentLimit = 4096

-- | Every model law's evidence, or a diagnostic for one that names no model,
-- command, property or predicate. ran: whether a checking layer is
-- selected.
modelLawEvidence :: Bool -> [S.Unit] -> C.Program -> Either [Diagnostic] [Obligation]
modelLawEvidence ran units program = fmap concat $ forM units $ \u -> do
  let properties = concatMap S.temporalProperties [u' | u' <- units]
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
    formula <- either problem Right (formulaOf properties (S.unitName u) program (S.modelLawFormula law))
    if not ran then pure (obligation NotVerified "no law verification layers selected") else do
      let fairness = [if strong then Strong c else Weak c | (strong, c) <- S.modelLawFairness law]
          checked = do
            system <- systemOf program machine
            -- Every run holds P: no fair run holds not P. Some run holds P:
            -- a fair run holds P.
            outcome <- search stateLimit system fairness (if S.modelLawEvery law then negation formula else formula)
            pure outcome
          assumed = if null fairness then "" else " under " ++ intercalate " and " [if strong then "strong fairness for " ++ c else "fairness for " ++ c | (strong, c) <- S.modelLawFairness law]
      pure $ case checked of
        Left why -> obligation Unsupported why
        Right (Bounded n why) -> obligation Incomplete ("no counterexample in the first " ++ show n ++ " states; " ++ why)
        Right (NoRun n)
          | S.modelLawEvery law -> obligation Proved ("every run holds it" ++ assumed ++ ": all " ++ show n ++ " states explored")
          | otherwise -> obligation Refuted ("no run holds it" ++ assumed ++ ": all " ++ show n ++ " states explored")
        Right (Lasso prefix cycle')
          | S.modelLawEvery law -> obligation Refuted ("a run breaks it" ++ assumed ++ ": " ++ trace prefix cycle')
          | otherwise -> obligation Proved ("a run holds it" ++ assumed ++ ": " ++ trace prefix cycle')
  where
    forM_' xs f = mapM_ f xs
    -- place, pay, (capture, refund): the steps, then the steps repeated.
    -- A run that ends stays in its last state.
    trace prefix cycle'
      | not (null cycle') && all (== "stays") cycle' =
          intercalate ", " (reverse (dropWhile (== "stays") (reverse prefix)) ++ ["then stays"])
      | otherwise = intercalate ", " (prefix ++ ["(" ++ intercalate ", " cycle' ++ ")" | not (null cycle')])

-- | The property as LTL in negation normal form: its words expanded, each
-- atom a Bool function of the model state.
formulaOf :: [S.TemporalProperty] -> String -> C.Program -> S.RunFormula -> Either String Formula
formulaOf properties unit program = go (10 :: Int) M.empty
  where
    go depth bound f = case f of
      S.TemporalAtom name _ -> case M.lookup name bound of
        Just argument -> go depth M.empty argument
        Nothing -> case [p | p <- properties, S.temporalSignature p == [Left name]] of
          p : _ -> expand depth p []
          [] -> atom name
      S.TemporalNot a -> negation <$> go depth bound a
      S.TemporalAnd a b -> FAnd <$> go depth bound a <*> go depth bound b
      S.TemporalOr a b -> FOr <$> go depth bound a <*> go depth bound b
      S.TemporalImplies a b -> FOr <$> (negation <$> go depth bound a) <*> go depth bound b
      S.TemporalAlways a -> FRelease FFalse <$> go depth bound a
      S.TemporalEventually a -> FUntil FTrue <$> go depth bound a
      S.TemporalUntil a b -> FUntil <$> go depth bound a <*> go depth bound b
      S.TemporalWhenever p q -> do
        p' <- go depth bound p
        q' <- go depth bound q
        pure (FRelease FFalse (FOr (negation p') q'))
      -- never P before Q: not P, weakly until Q.
      S.TemporalNeverBefore p q -> do
        p' <- go depth bound p
        q' <- go depth bound q
        pure (FRelease q' (FOr (negation p') q'))
      S.TemporalWithin _ _ -> Left "a deadline (within) needs a model with time; see time in models"
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
    atom name = case [ d | cu <- C.programUnits program, C.idText (C.unitId cu) == unit, d <- C.unitDefinitions cu
                         , C.declarationName (C.definitionDeclaration d) == name ] of
      d : _ | length (C.definitionArguments d) == 1 -> Right (FAtom (C.idText (C.declarationId (C.definitionDeclaration d))))
            | otherwise -> Left (name ++ " must be a predicate of the model state alone")
      [] -> Left ("no property or predicate " ++ name ++ " of the model state")

-- | The model's reference as a transition system: a state is a model value
-- and the typestate indices; a step is a command with arguments, allowed by
-- its precondition and indices, computed by its reference definition.
systemOf :: C.Program -> Machine C.Id -> Either String (System (Value, [Integer]))
systemOf program machine = do
  ctx <- A.context program
  start <- maybe (Left "the model has no start") Right (machineStart machine)
  let definition name = case [d | cu <- C.programUnits program, d <- C.unitDefinitions cu, C.declarationId (C.definitionDeclaration d) == name] of
        d : _ -> Right d
        [] -> Left ("the model's reference " ++ C.idText name ++ " is not a checked definition")
      origin = C.GeneratedFrom (C.Id "model-check")
      call d values = do
        let binders = C.definitionArguments d
            result = snd (C.functionType (C.declarationType (C.definitionDeclaration d)))
            expr = C.Expr result (C.ExternalCall (C.declarationId (C.definitionDeclaration d))
              [C.Expr (C.binderType b) (C.Local (C.binderId b)) origin | b <- binders]) origin
        A.contextEvaluate ctx (zip (map C.binderId binders) values) expr
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
    argumentTuples <- tuples arguments
    pure (c, ref, guard', argumentTuples)
  let steps (state, indices) = fmap concat $ forM references $ \(c, ref, guard', argumentTuples) -> do
        allowed <- case guard' of
          Nothing -> Right True
          Just g -> (== ScalarValue (SBool True)) <$> call g [state]
        if not allowed || (indicesNeeded && not (admits c indices)) then Right [] else
          forM argumentTuples $ \values -> do
            result <- call ref (values ++ [state])
            next <- if commandReturnsUnit c then Right result else case result of
              DataValue _ _ [_, n] -> Right n
              _ -> Left ("the reference of " ++ commandName c ++ " did not give a result and a state")
            let shown = unwords (commandName c : map A.showValue values)
            pure (commandName c, shown, (next, if indicesNeeded then shifted c indices else indices))
      holds name (state, _) = do
        d <- definition (C.Id name)
        v <- call d [state]
        pure (v == ScalarValue (SBool True))
  pure (System starts steps holds (\(v, is) -> show (A.canonical v) ++ show is))
