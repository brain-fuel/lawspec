-- | Z3 tasks for the law-set checks the compiler cannot decide by itself
-- (Core.LawAnalysis), and how their answers become the checks' outcomes.
--
-- Each task is a ground lawspec-smtlib-v2 query (Core.Smt.groundQuery)
-- that looks for a counterexample: an uncovered input, an input two laws
-- both decide, an input two clauses decide differently, or (for vacuity) a
-- witness that some input satisfies a law's assumptions. The host runs it
-- and sends Z3's answer back; the compiler confirms every model with the
-- reference evaluator before it counts, so a refutation never rests on Z3
-- alone. unsat proves a check, trusting the translation and Z3, as a
-- proved law does; for vacuity, unsat shows the law vacuous.
-- ref:DEC-law-set-analysis
module LawSpec.Core.LawTasks
  ( Purpose(..), AnalysisTask(..), Answer(..), analysisTasks, settle
  ) where

import Control.Monad (foldM, forM, zipWithM)
import qualified Data.ByteString as B
import Data.List (nub)
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import LawSpec.Core
import LawSpec.Core.Counterexample (readValues, valueOf)
import LawSpec.Core.Eval (validateValueWithContracts)
import LawSpec.Core.LawAnalysis
import LawSpec.Core.Smt (Ground(..), groundQuery, catalog, outerQuantifiers)
import LawSpec.Core.Value (Value(..), equalValues)
import LawSpec.Digest (digestHex, digestString)
import LawSpec.Scalar (Scalar(..))

data Purpose = Uncovered | Overlapping Clause Clause | Conflicting Clause Clause | Witness Property
  deriving (Eq, Show)

data AnalysisTask = AnalysisTask
  { taskUnit :: Id, taskFunction :: Id, taskCheck :: Check, taskPurpose :: Purpose
  -- The constants, and for each the identity its value binds when the
  -- evaluator confirms a model (a second clause's inputs are copies).
  , taskBinders :: [(Binder, Id)], taskScript :: String, taskNames :: [String], taskFingerprint :: String }
  deriving (Eq, Show)

-- | What the host saw: sat, unsat or another outcome, and on sat Z3's
-- get-value answer.
data Answer = Answer { answerOutcome :: String, answerValues :: String } deriving (Eq, Show)

-- | The tasks of each undecided row, or why it cannot have them.
analysisTasks :: Program -> M.Map Id Claims -> [Row] -> [(Row, Either String [AnalysisTask])]
analysisTasks program claims rows =
  [ (row, tasksOf row) | row <- rows, Undecided _ <- [rowOutcome row] ]
  where
    tasksOf row = do
      let f = rowFunction row
          clauses = clausesFor program f
          laws = lawsCalling program f
          build purpose binders assertions = do
            (script, names) <- groundQuery program (checkStage (rowCheck row) ++ " of " ++ idText f) (map fst binders) assertions
            pure (AnalysisTask (rowUnit row) f (rowCheck row) purpose binders script names
              (digestHex (digestString (concatMap frame [idText f, checkStage (rowCheck row), script]))))
      tasks <- case rowCheck row of
        Completeness -> do
          binders <- maybe (Left "the function has no arguments to quantify") Right (arguments program f)
          let locals = [Expr (binderType b) (Local (binderId b)) origin | b <- binders]
              origin = GeneratedFrom f
              contracts = [c | u <- programUnits program, c <- unitContracts u, contractDeclaration c == f]
              preconditions = [ holds (renamedTo (zip (contractArguments c) (map binderId binders)) p)
                              | c <- contracts, p <- contractPreconditions c ]
              scope = [holds condition | Just condition <- [claimsComplete =<< M.lookup f claims]]
          pure <$> build Uncovered [(b, binderId b) | b <- binders]
            (map Established (preconditions ++ scope) ++ [NotEstablished (coveredBy c locals) | c <- clauses])
        Overlap -> forM [ (c1, c2) | (i, c1) <- zip [0 :: Int ..] clauses, (j, c2) <- zip [0 ..] clauses, i < j
                        , propertyId (clauseLaw c1) /= propertyId (clauseLaw c2) ] $ \(c1, c2) ->
            uncurry (build (Overlapping c1 c2)) (pair c1 c2 False)
        Conflict -> forM [ (c1, c2) | (i, c1) <- zip [0 :: Int ..] clauses, (j, c2) <- zip [0 ..] clauses, i < j ] $ \(c1, c2) ->
            uncurry (build (Conflicting c1 c2)) (pair c1 c2 True)
        Vacuity -> forM laws $ \law -> do
          let (qs, body) = outerQuantifiers law
              bool = scalarType "Bool"
              origin = GeneratedFrom (propertyId law)
              constant b = Expr bool (Constant (SBool b)) origin
              conjoin a b = Expr bool (ShortCircuit And a b) origin
              disjoin a b = Expr bool (ShortCircuit Or a b) origin
              reachable = foldr disjoin (constant False) [foldr conjoin (constant True) path | path <- assumptions body]
          build (Witness law) [(quantifiedBinder q, binderId (quantifiedBinder q)) | q <- qs]
            ([Established (holds p) | q <- qs, p <- quantifiedPredicates q] ++ [Established (holds reachable)])
      if length tasks > 200 then Left "too many clause pairs for Z3 tasks" else pure tasks
    -- Two clauses at one input: the second clause's inputs are fresh copies.
    pair c1 c2 conflicting =
      let copies = [ (q, Binder (Id (idText (binderId (quantifiedBinder q)) ++ "#second")) (binderName (quantifiedBinder q))
                       (binderType (quantifiedBinder q))) | q <- clauseInputs c2 ]
          rename = renamedTo [(quantifiedBinder q, binderId copy) | (q, copy) <- copies]
          ty e = expressionType e
          assertions =
            [Established (holds p) | q <- clauseInputs c1, p <- quantifiedPredicates q] ++
            [Established (holds (rename p)) | q <- clauseInputs c2, p <- quantifiedPredicates q] ++
            [Established (holds g) | g <- clauseGuards c1] ++ [Established (holds (rename g)) | g <- clauseGuards c2] ++
            [Established (Equation (Structural (ty a)) a (rename b)) | (a, b) <- zip (clauseArguments c1) (clauseArguments c2)] ++
            [Established (Negation (Equation (Structural (ty (clauseOutcome c1))) (clauseOutcome c1) (rename (clauseOutcome c2)))) | conflicting]
      in ([(quantifiedBinder q, binderId (quantifiedBinder q)) | q <- clauseInputs c1] ++
          [(copy, binderId (quantifiedBinder q)) | (q, copy) <- copies], assertions)
    frame value = show (B.length (T.encodeUtf8 (T.pack value))) ++ ":" ++ value

holds :: Expr -> Proposition
holds e = Equation (Structural bool) e (Expr bool (Constant (SBool True)) (expressionOrigin e))
  where bool = scalarType "Bool"

-- | An expression over some binders, read over other identities: each
-- binder is let-bound to the new identity.
renamedTo :: [(Binder, Id)] -> Expr -> Expr
renamedTo pairs e = foldr (\(binder, fresh) body ->
  Expr (expressionType body) (Let binder (Expr (binderType binder) (Local fresh) (expressionOrigin body)) body) (expressionOrigin body)) e pairs

-- | The rows the tasks' answers settle, with exemptions as Core.LawAnalysis
-- attaches them. A model that the evaluator does not confirm settles
-- nothing and is reported.
settle :: Program -> M.Map Id Claims -> [(Row, [(AnalysisTask, Answer)])] -> [(Row, [(AnalysisTask, String, String)])]
settle program claims results =
  [ (row { rowOutcome = outcome, rowExemption = maybe (rowExemption row) Just vacuityExemption }, verdicts)
  | (row, answered) <- results
  , let verdicts = [(task, status, why) | (task, answer) <- answered, let (status, why) = verdict task answer]
        exemptions = maybe [] claimsExemptions (M.lookup (rowFunction row) claims)
        (outcome, vacuityExemption) = combine row verdicts exemptions ]
  where
    ctx = context program
    names f = parameterNames program f
    verdict task answer = case answerOutcome answer of
      "unsat" -> case taskPurpose task of
        Witness law -> ("refuted", vacuousText (propertyName law) ++ "; Z3 found no input, trusting the translation and Z3")
        _ -> ("proved", "Z3 found no counterexample, trusting the translation and Z3")
      "sat" -> either (\why -> ("incomplete", "Z3's model is not confirmed: " ++ why)) id $ do
        c <- ctx
        named <- readValues (answerValues answer)
        values <- forM (zip (taskNames task) (taskBinders task)) $ \(name, (binder, _)) ->
          maybe (Left ("Z3 gave no value for " ++ binderName binder)) (valueOf (catalog program) (binderType binder)) (lookup name named)
        let env = [(identity, v) | ((_, identity), v) <- zip (taskBinders task) values]
            split k = splitAt (length (clauseInputs k)) env
        confirm c task env split values
      other -> ("incomplete", case taskPurpose task of
        Overlapping _ _ -> "a suspected overlap Z3 cannot resolve (" ++ other ++ ")"
        Conflicting _ _ -> "a suspected conflict Z3 cannot resolve (" ++ other ++ ")"
        Uncovered -> "Z3 cannot decide whether an input is uncovered (" ++ other ++ ")"
        Witness _ -> "Z3 cannot decide whether the assumptions can hold (" ++ other ++ ")")
    confirm c task env split values = case taskPurpose task of
      Uncovered -> do
        let f = taskFunction task
        inDomain <- admitted c f values
        if not inDomain then Right ("model-not-confirmed", "Z3's input is outside the function's domain") else do
          coveredBySome <- anyClause c f values
          pure (if coveredBySome then ("model-not-confirmed", "a law covers Z3's input")
                else ("refuted", "not covered: " ++ shown (names f) values))
      Overlapping c1 c2 -> do
        let (env1, env2) = split c1
        ok <- both c env1 env2 c1 c2
        pure (if ok then ("refuted", propertyName (clauseLaw c1) ++ " and " ++ propertyName (clauseLaw c2) ++ " both apply to " ++
                 point c (taskFunction task) env1 c1)
              else ("model-not-confirmed", "the two laws do not both apply at Z3's input"))
      Conflicting c1 c2 -> do
        let (env1, env2) = split c1
        ok <- both c env1 env2 c1 c2
        r1 <- contextEvaluate c env1 (clauseOutcome c1)
        r2 <- contextEvaluate c env2 (clauseOutcome c2)
        same <- equalValues (contextBits c) r1 r2
        pure (if ok && not same then ("refuted", propertyName (clauseLaw c1) ++ " requires " ++ showValue r1 ++ " and " ++
                 propertyName (clauseLaw c2) ++ " requires " ++ showValue r2 ++ " for " ++ point c (taskFunction task) env1 c1)
              else ("model-not-confirmed", "the two clauses do not decide Z3's input differently"))
      Witness law -> do
        let (qs, body) = outerQuantifiers law
        inputs <- allM' (\q -> allM' (truthIn c env) (quantifiedPredicates q)) qs
        reachable <- anyM' (allM' (truthIn c env)) (assumptions body)
        pure (if inputs && reachable then ("proved", "an input satisfies the assumptions of " ++ propertyName law ++ ", confirmed by the evaluator")
              else ("model-not-confirmed", "Z3's input does not satisfy the assumptions of " ++ propertyName law))
    both c env1 env2 c1 c2 = do
      a <- allM' (truthIn c env1) ([p | q <- clauseInputs c1, p <- quantifiedPredicates q] ++ clauseGuards c1)
      b <- allM' (truthIn c env2) ([p | q <- clauseInputs c2, p <- quantifiedPredicates q] ++ clauseGuards c2)
      args1 <- mapM (contextEvaluate c env1) (clauseArguments c1)
      args2 <- mapM (contextEvaluate c env2) (clauseArguments c2)
      equal <- and <$> zipWithM (equalValues (contextBits c)) args1 args2
      pure (a && b && equal)
    point c f env clause = either (const "Z3's input") id $ do
      args <- mapM (contextEvaluate c env) (clauseArguments clause)
      pure (shown (names f) args)
    -- The function's input: its types, its preconditions, its complete over.
    admitted c f values = do
      binders <- maybe (Left "no arguments") Right (arguments program f)
      typed <- pure (all (\(b, v) -> either (const False) (const True) (validateValueWithContracts (contextRegistry c) (contextBits c) (binderType b) v)) (zip binders values))
      let env = zip (map binderId binders) values
          contracts = [k | u <- programUnits program, k <- unitContracts u, contractDeclaration k == f]
      pre <- allM' (\(k, p) -> truthIn c (zip (map binderId (contractArguments k)) values) p) [(k, p) | k <- contracts, p <- contractPreconditions k]
      scoped <- case claimsComplete =<< M.lookup f claims of
        Nothing -> Right True
        Just condition -> truthIn c env condition
      pure (typed && pre && scoped)
    anyClause c f values = anyM' (\clause -> coversPoint c (lawLimit (lawsCalling program f)) clause values) (clausesFor program f)
    combine row verdicts exemptions = case rowCheck row of
      Vacuity -> case [why | (_, "refuted", why) <- verdicts] of
        whys@(_ : _) ->
          let excused why = [e | e <- exemptions, exemptCheck e == Vacuity, Just law <- [exemptLaw e], take (length (vacuousText law)) why == vacuousText law]
              open = [why | why <- whys, null (excused why)]
          in case open of
            why : _ -> (Fails why, Nothing)
            [] -> case whys of
              why : _ -> (Fails why, case excused why of e : _ -> Just e; [] -> Nothing)
              [] -> (rowOutcome row, Nothing)
        [] | all (\(_, s, _) -> s == "proved") verdicts -> (Proven "Z3 found inputs satisfying every law's assumptions, each confirmed by the evaluator", Nothing)
           | otherwise -> (undecided verdicts, Nothing)
      _ -> case [why | (_, "refuted", why) <- verdicts] of
        why : _ -> (Fails (why ++ "; Z3 found it and the evaluator confirms it"), Nothing)
        [] | all (\(_, s, _) -> s == "proved") verdicts -> (Proven "Z3 found no counterexample, trusting the translation and Z3", Nothing)
           | otherwise -> (undecided verdicts, Nothing)
    undecided verdicts = Undecided (case [why | (_, s, why) <- verdicts, s /= "proved"] of
      why : _ -> why
      [] -> "no Z3 answer")

-- | Whether a clause covers an input: its arguments are matched against
-- the input's values, which binds the law's inputs they name; the rest are
-- enumerated when finite. Left when it cannot be decided.
coversPoint :: Context -> Int -> Clause -> [Value] -> Either String Bool
coversPoint c limit clause values = do
  let inputs = clauseInputs clause
      ids = map (binderId . quantifiedBinder) inputs
  matched <- foldM (\known (arg, v) -> case known of
      Nothing -> Right Nothing
      Just binds -> fmap (fmap (binds ++)) (match c ids M.empty arg v)) (Just []) (zip (clauseArguments clause) values)
  case matched of
    Nothing -> Right False
    Just binds -> do
      let bound = nub binds
      if length (nub (map fst bound)) /= length bound then Right False else do
        envs <- enumerateFrom c limit bound [q | q <- inputs, binderId (quantifiedBinder q) `notElem` map fst bound]
        anyM' (\env -> allM' (truthIn c env) ([p | q <- inputs, p <- quantifiedPredicates q] ++ clauseGuards clause)) envs

-- | A clause argument against a value: Just the law inputs it binds, or
-- Nothing when it cannot produce the value.
match :: Context -> [Id] -> M.Map Id Expr -> Expr -> Value -> Either String (Maybe [(Id, Value)])
match c ids aliases e v = case expressionNode e of
  Local x | x `elem` ids -> Right (Just [(x, v)])
          | Just aliased <- M.lookup x aliases -> match c ids aliases aliased v
  Let binder value body -> match c ids (M.insert (binderId binder) value aliases) body v
  Construct tag fields -> case v of
    DataValue _ tag' vs | tag == tag', length vs == length fields ->
      foldM (\known (field, fv) -> case known of
        Nothing -> Right Nothing
        Just binds -> fmap (fmap (binds ++)) (match c ids aliases field fv)) (Just []) (zip fields vs)
    _ -> Right Nothing
  _ | closed e -> do
        actual <- contextEvaluate c [] e
        same <- equalValues (contextBits c) actual v
        pure (if same then Just [] else Nothing)
    | otherwise -> Left "a law's argument is not a pattern of its inputs"
  where
    closed x = case expressionNode x of
      Local y -> y `notElem` ids && M.notMember y aliases
      _ -> all closed (children x)

allM' :: (a -> Either String Bool) -> [a] -> Either String Bool
allM' _ [] = Right True
allM' p (x : xs) = p x >>= \b -> if b then allM' p xs else Right False

anyM' :: (a -> Either String Bool) -> [a] -> Either String Bool
anyM' _ [] = Right False
anyM' p (x : xs) = p x >>= \b -> if b then Right True else anyM' p xs
