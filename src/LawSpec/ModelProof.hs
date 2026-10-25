-- | Z3 for model laws the explicit search cannot finish (an unbounded state,
-- or arguments with no finite domain): an invariant claim (every run holds
-- always S) is proved by induction (it holds at the start and every command
-- keeps it), or by an invariant Spacer proposes and plain queries re-check;
-- and a bounded run search looks for a step that breaks it, which the
-- reference evaluator replays before it is reported. ref:DEC-model-induction
module LawSpec.ModelProof
  ( ModelTask(..), Answer(..), modelTasks, settleModel, invariantClaims
  ) where

import Control.Monad (forM, unless, when)
import Data.Char (isSpace)
import Data.List (intercalate, isPrefixOf, isInfixOf, nub)
import qualified Data.Map.Strict as M
import LawSpec.Dependencies (dependencyGraphWithBits, semanticKey)
import LawSpec.Common
import qualified LawSpec.Core as C
import LawSpec.Core.Counterexample (SExpression(..), readValues, valueOf)
import LawSpec.Core.Evidence (Obligation(..), Status(..))
import qualified LawSpec.Core.LawAnalysis as A
import LawSpec.Core.Machine (Machine(..), MachineStart(..), Command(..))
import LawSpec.Core.Smt (Ground(..), ModelShape(..), groundQuery, hornQuery, invariantQueries, catalog)
import LawSpec.Core.Value (Value(..))
import LawSpec.Digest (digestHex, digestString)
import LawSpec.Scalar (Scalar(..))
import qualified LawSpec.Model as S
import LawSpec.ModelLaws (expandFormula, predicateOf, systemOf, ModelRun(..))
import LawSpec.Core.ModelCheck (System(..))

-- | A task: which law, what it asks (induction, a step, Spacer, an
-- invariant re-check, a bounded run), its script, and the constants whose
-- values a model gives.
data ModelTask = ModelTask
  { taskOwner :: C.Id, taskLaw :: C.Id, taskKind :: String, taskScript :: String
  , taskInputs :: [String], taskFingerprint :: String, taskSemanticFingerprint :: String }

-- | Z3's answer to a task: its outcome, its get-value answer, and, for
-- Spacer, the invariant it proposed (a define-fun of Inv).
data Answer = Answer { answerOutcome :: String, answerValues :: String, answerInvariant :: String, answerInputs :: Maybe [String] }

-- | The depth of the bounded run search.
depth :: Int
depth = 8

-- | The model laws that claim an invariant (every run holds always S), with
-- their model, claim and shape.
invariantClaims :: [S.Unit] -> C.Program -> [(C.Id, C.Id, Machine C.Id, ModelShape, [(String, [C.Binder], Maybe C.Expr, C.Expr)])]
invariantClaims units program =
  [ (C.Id (S.unitName u), C.Id (S.unitName u ++ "::law::" ++ S.modelLawName law), machine, shape, steps)
  | u <- units, law <- S.modelLaws u, S.modelLawEvery law
  , Right (S.TemporalAlways claim) <- [expandFormula (concatMap S.temporalProperties units) (S.modelLawFormula law)]
  , machine <- [m | cu <- C.programUnits program, C.idText (C.unitId cu) == S.unitName u, m <- C.unitMachines cu, machineName m == S.modelLawModel law]
  , machineIndices machine == 0
  , Right (shape, steps) <- [shapeOf program (S.unitName u) machine claim] ]

-- | The model as Core over a state binder: start, steps and claim.
shapeOf :: C.Program -> String -> Machine C.Id -> S.RunFormula -> Either String (ModelShape, [(String, [C.Binder], Maybe C.Expr, C.Expr)])
shapeOf program unit machine claim = do
  start <- maybe (Left "no start") Right (machineStart machine)
  startDefinition <- definition (startModel start)
  commands <- forM [c | c <- machineCommands machine, not (commandRestart c)] $ \c -> do
    ref <- definition (commandReference c)
    guard' <- traverse definition (commandWhen c)
    when (null (C.definitionArguments ref)) (Left "a reference takes no state")
    pure (c, ref, guard')
  stateType <- case commands of
    (_, ref, _) : _ -> Right (C.binderType (last (C.definitionArguments ref)))
    [] -> Right (resultOf startDefinition)
  let state = C.Binder (C.Id "lawspec::model::state") "state" stateType
      local b = C.Expr (C.binderType b) (C.Local (C.binderId b)) origin
      startArguments = C.definitionArguments startDefinition
  claimExpr <- predicateExpr claim (local state)
  steps <- forM commands $ \(c, ref, guard') -> do
    let arguments = init (C.definitionArguments ref)
        refCall = call ref (map local arguments ++ [local state])
    next <- if commandReturnsUnit c then Right refCall else second refCall
    pure (commandName c, arguments, (\g -> call g [local state]) <$> guard', next)
  pure (ModelShape state (startArguments, call startDefinition (map local startArguments)) steps claimExpr, steps)
  where
    origin = C.GeneratedFrom (C.Id "model-proof")
    definition name = case [d | cu <- C.programUnits program, d <- C.unitDefinitions cu, C.declarationId (C.definitionDeclaration d) == name] of
      d : _ -> Right d
      [] -> Left ("the model's reference " ++ C.idText name ++ " is not a checked definition")
    resultOf d = snd (C.functionType (C.declarationType (C.definitionDeclaration d)))
    call d arguments = C.Expr (resultOf d) (C.ExternalCall (C.declarationId (C.definitionDeclaration d)) arguments) origin
    bool = C.Constructor "Bool" []
    -- A reference's next state: the second field of its Pair result.
    second e = case C.expressionType e of
      ty@(C.Constructor name arguments) -> case [d | d <- C.programDataDeclarations program, C.idText (C.dataId d) == name] of
        d : _ | [c] <- C.dataConstructors d, [_, f] <- C.constructorFields c ->
          let table = zip (C.dataParameters d) [t | C.TypeArgument t <- arguments]
          in Right (C.Expr (substitute table (C.binderType f)) (C.Project (C.constructorId c) 1 e) origin)
        _ -> Left ("the reference's result " ++ show ty ++ " is not a result and a state")
      ty -> Left ("the reference's result " ++ show ty ++ " is not a result and a state")
    substitute table ty = case ty of
      C.TypeVariable v | Just t <- lookup v table -> t
      C.Constructor n args -> C.Constructor n [case a of C.TypeArgument t -> C.TypeArgument (substitute table t); other -> other | a <- args]
      other -> other
    predicateExpr f stateExpr = case f of
      S.TemporalAtom name _ -> do
        resolved <- predicateOf unit program name
        d <- definition (C.Id resolved)
        Right (call d [stateExpr])
      S.TemporalNot a -> (\x -> C.Expr bool (C.Unary C.Not x) origin) <$> predicateExpr a stateExpr
      S.TemporalAnd a b -> (\x y -> C.Expr bool (C.ShortCircuit C.And x y) origin) <$> predicateExpr a stateExpr <*> predicateExpr b stateExpr
      S.TemporalOr a b -> (\x y -> C.Expr bool (C.ShortCircuit C.Or x y) origin) <$> predicateExpr a stateExpr <*> predicateExpr b stateExpr
      S.TemporalImplies a b -> (\x y -> C.Expr bool (C.ShortCircuit C.Or (C.Expr bool (C.Unary C.Not x) origin) y) origin)
        <$> predicateExpr a stateExpr <*> predicateExpr b stateExpr
      _ -> Left "an invariant is a condition on one state"

-- | The tasks of each invariant law the search left open: induction (the
-- start, then each command), Spacer, any invariant re-checks its answer
-- needs, and the bounded run search.
modelTasks :: [S.Unit] -> C.Program -> [C.Id] -> [(String, Answer)] -> [(C.Id, C.Id, [ModelTask])]
modelTasks units program open answers =
  [ (owner, law, tasks owner law shape steps)
  | (owner, law, _, shape, steps) <- invariantClaims units program, law `elem` open ]
  where
    graph = dependencyGraphWithBits (C.programMachineBits program) (C.programDataDeclarations program) (C.programUnits program)
    tasks owner law shape steps =
      let shapeIdentity = (shapeState shape, shapeStart shape,
            [(arguments, guard', next) | (_,arguments,guard',next) <- steps], shapeClaim shape)
          ordinal kind = case lookup kind (zip ("induction: the start" : ["induction: " ++ name | (name,_,_,_) <- steps]) [0 :: Int ..]) of
            Just index -> "induction:" ++ show index
            Nothing -> kind
          task kind (script, inputs) = ModelTask owner law kind script inputs
            (digestHex (digestString (C.idText law ++ "\0" ++ kind ++ "\0" ++ script)))
            (semanticKey graph (show ("lawspec.model-goal.v1", C.programMachineBits program, ordinal kind,
              [answerInvariant a | "invariant: " `isPrefixOf` kind, (_,a) <- answers, not (null (answerInvariant a))])) shapeIdentity)
          state = shapeState shape
          bool = C.Constructor "Bool" []
          origin = C.GeneratedFrom (C.Id "model-proof")
          truth = C.Expr bool (C.Constant (SBool True)) origin
          holdsOf e = C.Equation (C.Structural bool) e truth
          claimAt e = C.Expr bool (C.Let state e (shapeClaim shape)) origin
          -- A proof needs the start and every command. If any obligation
          -- cannot be encoded, retaining only the others would prove less
          -- than the invariant. Keep the whole group incomplete instead.
          induction = either (const []) id $ do
            first <- groundQuery program "induction: the start" (fst (shapeStart shape))
                [NotEstablished (holdsOf (claimAt (snd (shapeStart shape))))]
            kept <- forM steps $ \(command, arguments, guard', next) -> do
              query <- groundQuery program ("induction: " ++ command) (state : arguments)
                ([Established (holdsOf (shapeClaim shape))] ++ [Established (holdsOf g) | Just g <- [guard']] ++
                 [NotEstablished (holdsOf (claimAt next))])
              pure (task ("induction: " ++ command) query)
            pure (task "induction: the start" first : kept)
          spacer = [task "spacer" (script, []) | Right script <- [hornQuery program shape]]
          spacerAnswer = [a | t <- spacer, Just a <- [lookup (taskFingerprint t) answers], answerOutcome a == "sat", not (null (answerInvariant a))]
          rechecks = case spacerAnswer of
            a : _ | Right invariant <- validInvariant (answerInvariant a)
                  , Right queries <- invariantQueries program shape invariant ->
                [task ("invariant: " ++ purpose) (script, []) | (purpose, script) <- queries]
            _ -> []
          bounded = [task "bounded search" r | Right r <- [boundedQuery program shape steps]]
      in induction ++ spacer ++ rechecks ++ bounded

-- | Spacer's invariant, as one define-fun of Inv: one balanced form that
-- defines Inv and nothing else.
validInvariant :: String -> Either String String
validInvariant text = do
  let trimmed = dropWhile isSpace text
      balanced = all (>= 0) depths && last' depths == 0
      depths = scanl (\n c -> n + (if c == '(' then 1 else if c == ')' then -1 else 0)) (0 :: Int) trimmed
      last' xs = if null xs then 0 else last xs
      top = length (filter id (zipWith (\d c -> d == 0 && c == '(') depths trimmed))
  unless ("(define-fun Inv " `isPrefixOf` trimmed) (Left "Spacer's answer does not define Inv")
  unless (balanced && top == 1) (Left "Spacer's answer is not one definition")
  when (any (`isInfixOf` trimmed) ["(assert", "(declare", "(push", "(pop", "(set-", "(check-sat", "(exit", "(reset", "(echo", "(define-fun-rec", "(define-funs-rec"])
    (Left "Spacer's answer holds commands")
  Right trimmed

-- | A run of at most depth steps, from a start, that reaches a state where
-- the claim fails: each step chooses a command (an integer) and its
-- arguments.
boundedQuery :: C.Program -> ModelShape -> [(String, [C.Binder], Maybe C.Expr, C.Expr)] -> Either String (String, [String])
boundedQuery program shape steps = do
  let state = shapeState shape
      bool = C.Constructor "Bool" []
      origin = C.GeneratedFrom (C.Id "model-proof")
      int32 = C.Constructor "Int32" []
      binder name ty = C.Binder (C.Id ("lawspec::run::" ++ name)) name ty
      local b = C.Expr (C.binderType b) (C.Local (C.binderId b)) origin
      states = [binder ("state" ++ show i) (C.binderType state) | i <- [0 .. depth]]
      choices = [binder ("choice" ++ show i) int32 | i <- [0 .. depth - 1]]
      argumentsAt i k arguments = [binder ("argument" ++ show i ++ "_" ++ show k ++ "_" ++ show j) (C.binderType a) | (j, a) <- zip [0 :: Int ..] arguments]
      stepArguments = [[argumentsAt i k arguments | (k, (_, arguments, _, _)) <- zip [0 :: Int ..] steps] | i <- [0 .. depth - 1]]
      truth = C.Expr bool (C.Constant (SBool True)) origin
      holdsOf e = C.Equation (C.Structural bool) e truth
      equal a b = C.Expr bool (C.Binary C.Equal (C.Structural (C.expressionType a)) a b) origin
      both' a b = C.Expr bool (C.ShortCircuit C.And a b) origin
      either' a b = C.Expr bool (C.ShortCircuit C.Or a b) origin
      none = C.Expr bool (C.Constant (SBool False)) origin
      bindAll pairs body = foldr (\(b, value) inner -> C.Expr (C.expressionType inner) (C.Let b value inner) origin) body pairs
      startArguments = [binder ("start" ++ show j) (C.binderType a) | (j, a) <- zip [0 :: Int ..] (fst (shapeStart shape))]
      first = bindAll (zip (fst (shapeStart shape)) (map local startArguments)) (snd (shapeStart shape))
      stepAt i = foldr either' none
        [ foldr1 both' ([ equal (local (choices !! i)) (C.Expr int32 (C.Constant (SInteger "Int32" (toInteger k))) origin) ] ++
            [ bindAll [(state, local (states !! i))] g | Just g <- [guard'] ] ++
            [ equal (local (states !! (i + 1))) (bindAll ((state, local (states !! i)) : zip arguments (map local (stepArguments !! i !! k))) next) ])
        | (k, (_, arguments, guard', next)) <- zip [0 :: Int ..] steps ]
      broken = foldr either' none [C.Expr bool (C.Unary C.Not (bindAll [(state, local s)] (shapeClaim shape))) origin | s <- states]
      binders = startArguments ++ states ++ choices ++ concat (concat stepArguments)
  when (null steps) (Left "the model has no commands")
  groundQuery program ("a run of at most " ++ show depth ++ " steps that breaks the claim") binders
    ([Established (holdsOf (equal (local (head states)) first))] ++ [Established (holdsOf (stepAt i)) | i <- [0 .. depth - 1]] ++
     [Established (holdsOf broken)])

-- | Each law's result from Z3's answers: refuted by a run the evaluator
-- replays, proved by induction or by a re-checked invariant, or still
-- incomplete with what was found.
settleModel :: [S.Unit] -> C.Program -> [(C.Id, C.Id, [ModelTask])] -> [(String, Answer)] -> [ModelRun]
settleModel units program tasks answers =
  [ ModelRun owner law status reason
  | (owner, law, ts) <- tasks
  , let answered = [(t, a) | t <- ts, Just a <- [lookup (taskFingerprint t) answers]]
        outcome kind = [a | (t, a) <- answered, taskKind t == kind]
        inductive = [t | t <- ts, "induction: " `isPrefixOf` taskKind t]
        rechecks = [t | t <- ts, "invariant: " `isPrefixOf` taskKind t]
        allUnsat group = not (null group) && all (\t -> maybe False ((== "unsat") . answerOutcome) (lookup (taskFingerprint t) answers)) group
        spacerInvariant = [answerInvariant a | (t, a) <- answered, taskKind t == "spacer"]
        replayed = case [ (t, a) | (t, a) <- answered, taskKind t == "bounded search", answerOutcome a == "sat" ] of
          (t, a) : _ -> replay units program owner law t a
          [] -> Nothing
        (status, reason) = case replayed of
          Just (Right run) -> (Refuted, "a run breaks it: " ++ run ++ "; Z3 found it and the evaluator replays it")
          _ | allUnsat inductive -> (Proved, "by induction: it holds at the start and every command keeps it; trusts the typed translation and Z3")
            | allUnsat rechecks -> (Proved, "by the invariant " ++ unwords (words (concat (take 1 spacerInvariant))) ++
                ", which Spacer proposed and plain queries re-checked; trusts the typed translation and Z3")
            | otherwise -> (Incomplete, intercalate "; " ([ "it is not inductive: " ++ intercalate ", " [drop 11 (taskKind t) | t <- inductive, maybe False ((== "sat") . answerOutcome) (lookup (taskFingerprint t) answers)]
                                                         | any (\t -> maybe False ((== "sat") . answerOutcome) (lookup (taskFingerprint t) answers)) inductive ] ++
                                                       [ "the start and every command could not all be encoded for induction" | null inductive ] ++
                                                       [ "no run of up to " ++ show depth ++ " steps breaks it" | [a] <- [outcome "bounded search"], answerOutcome a == "unsat" ] ++
                                                       [ "Z3 gave a run the evaluator does not replay: " ++ why | Just (Left why) <- [replayed] ]))
  ]

-- | The bounded search's run, replayed by the reference evaluator: Z3's
-- first state must be one the model starts in, and each chosen command
-- with Z3's arguments must be allowed and lead on, until a state where the
-- claim fails.
replay :: [S.Unit] -> C.Program -> C.Id -> C.Id -> ModelTask -> Answer -> Maybe (Either String String)
replay units program _ law task answer = Just $ do
  (_, _, machine, shape, steps) <- case [c | c@(_, l, _, _, _) <- invariantClaims units program, l == law] of
    c : _ -> Right c
    [] -> Left "the law has no invariant"
  pairs <- readValues (answerValues answer)
  let original = maybe (taskInputs task) id (answerInputs answer)
  unless (length original == length (taskInputs task) && length (nub original) == length original)
    (Left "the original model constants do not match the current task")
  system <- systemOf program machine
  ctx <- A.context program
  let types = catalog program
      names = original
      startCount = length (fst (shapeStart shape))
      valueAt i ty = case drop i names of
        n : _ | Just v <- lookup n pairs -> valueOf types ty v
        _ -> Left "Z3's run is missing a value"
      stateType = C.binderType (shapeState shape)
      choiceAt i = case drop (startCount + depth + 1 + i) names of
        n : _ | Just (Atom digits) <- lookup n pairs, not (null digits), all (`elem` ("0123456789" :: String)) digits -> Right (read digits :: Int)
        _ -> Left "Z3's run has no command choice"
      -- Where step i's arguments for command k begin.
      counts = [length arguments | (_, arguments, _, _) <- steps]
      argumentStart i k = startCount + (depth + 1) + depth + i * sum counts + sum (take k counts)
      holds v = (== ScalarValue (SBool True)) <$> A.contextEvaluate ctx [(C.binderId (shapeState shape), v)] (shapeClaim shape)
  first <- valueAt startCount stateType
  unless (any (\s -> systemKey system s == systemKey system (first, [])) (systemInitial system)) (Left "Z3's first state is not a start of the model")
  let walk s i shown = do
        ok <- holds (fst s)
        if not ok then Right (reverse shown) else if i >= depth then Left "no state on the run breaks the claim" else do
          k <- choiceAt i
          (command, arguments, _, _) <- if k >= 0 && k < length steps then Right (steps !! k) else Left "Z3 chose no command"
          values <- forM (zip [0 ..] arguments) (\(j, a) -> valueAt (argumentStart i k + j) (C.binderType a))
          moves <- systemSteps system s
          let label = unwords (command : map A.showValue values)
          case [s' | (c, shown', s') <- moves, c == command, shown' == label] of
            s' : _ -> walk s' (i + 1) (label : shown)
            [] -> Left (label ++ " is not allowed there")
  run <- walk (first, []) 0 []
  Right (if null run then "the start" else intercalate ", " run)
