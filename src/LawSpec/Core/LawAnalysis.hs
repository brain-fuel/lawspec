-- | The laws about a function, checked together (gate 5 increment 6). For
-- every function that has laws, LawSpec checks by default that:
--
-- * completeness: its outcome laws cover every input (or every input a
--   `complete over` condition admits);
-- * overlap: no two laws decide the same input;
-- * conflict: no two outcome clauses require different results for one
--   input;
-- * vacuity: some input satisfies each law's assumptions.
--
-- An outcome clause is a law (or a conjunct of it) of the form
-- `[guard implies] f args = outcome`, where the arguments and the outcome
-- are values of the law's inputs (they call no function) and the guard
-- does not call f: a row of a decision table. Other laws (properties such
-- as `f (f x) = f x`) take part in vacuity only. Checks over finite domains are decided here by the
-- reference evaluator, so every counterexample is a confirmed one; the
-- rest are Z3 tasks (Core.Smt), whose models the evaluator confirms too.
-- A `laws for f are ... end laws` block excuses checks, each with a reason
-- and optionally until a version or a UTC date-time.
-- ref:DEC-law-set-analysis
module LawSpec.Core.LawAnalysis
  ( Check(..), checkStage, checks, Until(..), Exemption(..), Claims(..), Outcome(..), Row(..)
  , Clause(..), clausesFor, analysedFunctions, lawsCalling, analyse, assumptions, coveredBy
  , Context(..), context, truthIn, canonical, showValue, shown, parameterNames, arguments, enumerateFrom
  , vacuousText, lawLimit
  ) where

import Data.List (nub, intercalate)
import qualified Data.Map.Strict as M
import LawSpec.Common (Generation(..), Quantification(..))
import LawSpec.Core
import LawSpec.Core.Definitions (prepareHookedDefinitions)
import LawSpec.Core.Eval (evaluateValue)
import LawSpec.Core.Smt (outerQuantifiers)
import LawSpec.Core.Types (TypeRegistry, makeRegistry)
import LawSpec.Core.Value (Value(..), equalValues)
import LawSpec.Scalar (Scalar(..), prettyScalar)
import LawSpec.Testing (finiteValuesWithRegistry)

data Check = Completeness | Overlap | Conflict | Vacuity deriving (Eq, Ord, Show, Enum, Bounded)

checks :: [Check]
checks = [minBound .. maxBound]

checkStage :: Check -> String
checkStage Completeness = "completeness"
checkStage Overlap = "overlap"
checkStage Conflict = "conflict"
checkStage Vacuity = "vacuity"

-- | A version of the project, or a UTC date-time.
data Until = UntilVersion String | UntilTime String deriving (Eq, Show)

-- | An excused check, with its law for vacuity.
data Exemption = Exemption
  { exemptCheck :: Check, exemptLaw :: Maybe String, exemptUntil :: Maybe Until, exemptReason :: String }
  deriving (Eq, Show)

-- | What a `laws for f are ... end laws` block says, elaborated: the
-- condition `complete over` names over f's arguments, and the exemptions.
data Claims = Claims { claimsFunction :: Id, claimsComplete :: Maybe Expr, claimsExemptions :: [Exemption] }
  deriving (Eq, Show)

data Outcome
  = Holds String
  -- A counterexample the reference evaluator confirmed, as text.
  | Fails String
  -- Not decided here: a Z3 task decides it.
  | Undecided String
  | Unsupported String
  -- Z3 found no counterexample (unsat), trusting the translation and Z3.
  | Proven String
  deriving (Eq, Show)

data Row = Row
  { rowUnit :: Id, rowFunction :: Id, rowCheck :: Check, rowOutcome :: Outcome, rowExemption :: Maybe Exemption }
  deriving (Eq, Show)

-- | [guard implies] f args = outcome, in a law with its outer inputs.
data Clause = Clause
  { clauseLaw :: Property, clauseInputs :: [Quantifier], clauseGuards :: [Expr]
  , clauseArguments :: [Expr], clauseOutcome :: Expr }
  deriving (Eq, Show)

userUnit :: Unit -> Bool
userUnit unit = not (any (`isPrefixOfId` unitId unit) ["lawspec.", "prelude"])
  where isPrefixOfId prefix (Id name) = take (length prefix) name == prefix

lawsCalling :: Program -> Id -> [Property]
lawsCalling program f =
  [ p | u <- programUnits program, userUnit u, p <- unitProperties u
  , null (propertyHandlers p), null (propertyResources p), any (calls f) (propertyExpressions p) ]

-- | The functions some user law calls: checked definitions and adapters.
analysedFunctions :: Program -> [(Id, Id)]
analysedFunctions program = nub
  [ (unitId u, declarationId d)
  | u <- programUnits program, userUnit u, d <- unitDeclarations u, isFunction (declarationType d)
  , not (generated (declarationId d)), not (null (lawsCalling program (declarationId d))) ]
  where isFunction (Arrow _ _) = True
        isFunction _ = False

-- | The compiler's own helpers (record views, specializations) have no laws
-- of their own to check together.
generated :: Id -> Bool
generated (Id name) = take 7 (reverse (takeWhile (/= ':') (reverse name))) == "lawspec"

-- | A value of the law's inputs: no call to any function or adapter.
value :: Expr -> Bool
value e = case expressionNode e of
  ExternalCall _ _ -> False
  Perform _ _ -> False
  _ -> all value (children e)

calls :: Id -> Expr -> Bool
calls f e = case expressionNode e of
  ExternalCall g arguments -> g == f || any (calls f) arguments
  _ -> any (calls f) (children e)

-- | The outcome clauses of f's laws.
clausesFor :: Program -> Id -> [Clause]
clausesFor program f = concatMap clauses (lawsCalling program f)
  where
    -- A law without inputs is an example: it says one result, not a case.
    clauses law = let (inputs, body) = outerQuantifiers law in if null inputs then [] else walk law inputs [] body
    walk law inputs guards proposition = case proposition of
      Implication guard body | not (calls f guard) -> walk law inputs (guards ++ [guard]) body
      Conjunction parts -> concatMap (walk law inputs guards) parts
      Equation _ a b
        | true b -> boolean law inputs guards a
        | true a -> boolean law inputs guards b
        | Just arguments <- call a, value b -> [Clause law inputs guards arguments b]
        | Just arguments <- call b, value a -> [Clause law inputs guards arguments a]
      _ -> []
    -- `g implies e` and `a and b` inside a Boolean claim lower to
    -- `not g or e` and `a && b`.
    boolean law inputs guards e = case expressionNode e of
      ShortCircuit And a b -> boolean law inputs guards a ++ boolean law inputs guards b
      ShortCircuit Or (Expr _ (Unary Not guard) _) body | not (calls f guard) -> boolean law inputs (guards ++ [guard]) body
      Binary Equal _ a b
        | Just arguments <- call a, value b -> [Clause law inputs guards arguments b]
        | Just arguments <- call b, value a -> [Clause law inputs guards arguments a]
      _ -> []
    call e = case expressionNode e of
      ExternalCall g arguments | g == f, all value arguments -> Just arguments
      Convert _ _ inner -> call inner
      _ -> Nothing

-- | Whether a law's assumptions can hold: its guards, along some path.
assumptions :: Proposition -> [[Expr]]
assumptions proposition = case proposition of
  Implication guard body -> map (guard :) (assumptions body)
  Conjunction parts -> concatMap assumptions parts
  Equation _ a b | true b -> paths a
                 | true a -> paths b
  _ -> [[]]
  where
    paths e = case expressionNode e of
      ShortCircuit And a b -> paths a ++ paths b
      ShortCircuit Or (Expr _ (Unary Not guard) _) body -> map (guard :) (paths body)
      _ -> [[]]

true :: Expr -> Bool
true e = case expressionNode e of
  Constant (SBool True) -> True
  _ -> False

-- | The reference evaluator over one program, built once per analysis.
data Context = Context
  { contextEvaluate :: [(Id, Value)] -> Expr -> Either String Value
  , contextRegistry :: TypeRegistry, contextBits :: Int }

context :: Program -> Either String Context
context program = do
  registry <- makeRegistry (programDataDeclarations program)
  hooked <- either (Left . concatMap show) Right (prepareHookedDefinitions program)
  let bits = programMachineBits program
  pure (Context (\env e -> evaluateValue registry bits (hooked (\_ _ -> Nothing)) env e) registry bits)

truthIn :: Context -> [(Id, Value)] -> Expr -> Either String Bool
truthIn ctx env e = case contextEvaluate ctx env e of
  Right (ScalarValue (SBool b)) -> Right b
  Right _ -> Left "a condition did not evaluate to a Boolean"
  Left message -> Left message

-- | Every check of f, decided where its domains are finite.
analyse :: Program -> M.Map Id Claims -> [Row]
analyse program claims = case context program of
  Left why -> [Row owner f check (Unsupported why) Nothing | (owner, f) <- analysedFunctions program, check <- checks]
  Right ctx ->
    [ Row owner f check outcome (maybe (exemption check) Just vacuityExemption)
    | (owner, f) <- analysedFunctions program
    , let clauses = clausesFor program f
          laws = lawsCalling program f
          claim = M.lookup f claims
          exemptions = maybe [] claimsExemptions claim
          exemption check = case [e | e <- exemptions, exemptCheck e == check, check /= Vacuity] of
            e : _ -> Just e
            [] -> Nothing
          limit = lawLimit laws
          -- Shared by completeness, overlap and conflict.
          coverage = mapM (covered ctx limit) clauses
    , check <- checks
    , applies f check clauses laws
    , let (outcome, vacuityExemption) = either (\why -> (Unsupported why, Nothing)) id
            (decide ctx program f clauses laws claim exemptions limit coverage check) ]
  where
    -- A law with no assumptions covers every input, and constrains some:
    -- such sets have nothing to check, and report no row.
    applies f Completeness clauses _ = not (null clauses) && not (any (total f) clauses)
    applies _ Overlap clauses _ = length (nub [propertyId (clauseLaw c) | c <- clauses]) >= 2
    applies _ Conflict clauses _ = length clauses >= 2
    applies _ Vacuity _ laws = any assumes laws
    total f c = null (clauseGuards c) && all unrestricted (clauseInputs c)
      && case arguments program f of
           Just parameters -> length parameters == length (clauseArguments c)
             && and [ binderType b == expressionType a && isInput a | (b, a) <- zip parameters (clauseArguments c) ]
             && length (nub [i | a <- clauseArguments c, Local i <- [expressionNode a]]) == length (clauseArguments c)
           Nothing -> False
      where isInput a = case expressionNode a of
              Local i -> i `elem` map (binderId . quantifiedBinder) (clauseInputs c)
              _ -> False
    unrestricted q = null (quantifiedPredicates q) && null (quantifiedBounds q)
    assumes law = let (inputs, body) = outerQuantifiers law
                  in not (all unrestricted inputs) || any (not . null) (assumptions body)

-- | The largest exhaustive limit of a function's laws.
lawLimit :: [Property] -> Int
lawLimit laws = maximum (4096 : [exhaustiveLimit (propertyGeneration l) | l <- laws])

-- | The inputs a clause covers: its arguments' values wherever its guards
-- hold, with the law's inputs there.
covered :: Context -> Int -> Clause -> Either String [([Value], (Clause, [(Id, Value)]))]
covered ctx limit c = do
  xs <- enumerate ctx limit (clauseInputs c)
  fmap concat $ mapM (\env -> do
    applies <- allM (truthIn ctx env) (clauseGuards c)
    if not applies then pure [] else do
      point <- mapM (contextEvaluate ctx env) (clauseArguments c)
      pure [(map canonical point, (c, env))]) xs

allM :: (a -> Either String Bool) -> [a] -> Either String Bool
allM _ [] = Right True
allM p (x : xs) = p x >>= \b -> if b then allM p xs else Right False

-- | A value's identity for comparing inputs: an integer is its number, in
-- whatever integer type it was computed.
canonical :: Value -> Value
canonical v = case v of
  ScalarValue (SInteger _ n) -> ScalarValue (SInteger "Integer" n)
  DataValue ty tag fields -> DataValue ty tag (map canonical fields)
  PresenceValue ty inner -> PresenceValue ty (fmap canonical inner)
  other -> other

-- | A check's outcome, and for vacuity the exemption of the vacuous law it
-- names.
decide :: Context -> Program -> Id -> [Clause] -> [Property] -> Maybe Claims -> [Exemption] -> Int
  -> Either String [[([Value], (Clause, [(Id, Value)]))]] -> Check -> Either String (Outcome, Maybe Exemption)
decide ctx program f clauses laws claim exemptions limit coverage check = do
  outcome <- decideCheck ctx program f clauses laws claim exemptions limit coverage check
  pure $ case (check, outcome) of
    -- A vacuous law its block excuses carries that exemption.
    (Vacuity, Fails why) | e : _ <- [e | e <- exemptions, exemptCheck e == Vacuity, Just law <- [exemptLaw e], why == vacuousText law] ->
      (outcome, Just e)
    _ -> (outcome, Nothing)

vacuousText :: String -> String
vacuousText name = "no input satisfies the assumptions of " ++ name

decideCheck :: Context -> Program -> Id -> [Clause] -> [Property] -> Maybe Claims -> [Exemption] -> Int
  -> Either String [[([Value], (Clause, [(Id, Value)]))]] -> Check -> Either String Outcome
decideCheck ctx program f clauses laws claim exemptions limit coverage check = case check of
  Completeness -> case (domain ctx limit program f, coverage) of
    (Right points, Right covers) -> do
      let known = M.fromList [(p, ()) | (p, _) <- concat covers]
      scoped <- case claimsComplete =<< claim of
        Nothing -> pure points
        Just condition -> filterM' (\env -> truthIn ctx env condition) points
      pure $ case [p | env <- scoped, let p = map snd env, M.notMember (map canonical p) known] of
        p : _ -> Fails ("not covered: " ++ shown named p)
        [] -> Holds ("the compiler checked every input against the " ++ show (length clauses) ++ " outcome clause(s)")
    _ -> undecided
  Overlap -> case coverage of
    Right covers -> pure $ case [ (p, l1, l2) | (p, owners) <- M.toList (M.fromListWith (++) [(p, [propertyName (clauseLaw c)]) | (p, (c, _)) <- concat covers])
                                 , (l1 : l2 : _) <- [nub (reverse owners)] ] of
      (p, l1, l2) : _ -> Fails (l1 ++ " and " ++ l2 ++ " both apply to " ++ shown named p)
      [] -> Holds "no two laws apply to the same input"
    Left _ -> undecided
  Conflict -> case coverage of
    Right covers -> do
      let byPoint = M.fromListWith (++) [(p, [(c, env)]) | (p, (c, env)) <- concat covers]
      found <- firstConflict (contextEvaluate ctx) (contextBits ctx) (M.toList byPoint)
      pure $ case found of
        Just (p, (c1, r1), (c2, r2)) -> Fails (propertyName (clauseLaw c1) ++ " requires " ++ showValue r1 ++ " and " ++
          propertyName (clauseLaw c2) ++ " requires " ++ showValue r2 ++ " for " ++ shown named p)
        Nothing -> Holds "no two outcome clauses require different results for one input"
    Left _ -> undecided
  Vacuity -> do
    let excused law = any (\e -> exemptCheck e == Vacuity && exemptLaw e == Just (propertyName law)) exemptions
        vacuous law = do
          let (qs, body) = outerQuantifiers law
          xs <- enumerate ctx limit qs
          reachable <- anyM (\env -> anyM (allM (truthIn ctx env)) (assumptions body)) xs
          pure (not reachable)
        results = [(law, vacuous law) | law <- laws]
    pure $ case ([propertyName law | (law, Right True) <- results, not (excused law)],
                 [propertyName law | (law, Right True) <- results, excused law]) of
      (name : _, _) -> Fails (vacuousText name)
      ([], _) | any (either (const True) (const False) . snd) results -> Undecided "a law's domain is not finite or too large for the compiler; a Z3 task decides it"
      ([], name : _) -> Fails (vacuousText name)
      ([], []) -> Holds "some input satisfies every law's assumptions"
  where
    undecided = Right (Undecided "a domain is not finite or too large for the compiler; a Z3 task decides it")
    named = parameterNames program f
    filterM' p xs = fmap concat (mapM (\x -> (\keep -> [x | keep]) <$> p x) xs)

anyM :: (a -> Either String Bool) -> [a] -> Either String Bool
anyM _ [] = Right False
anyM p (x : xs) = p x >>= \b -> if b then Right True else anyM p xs

firstConflict :: (env -> Expr -> Either String Value) -> Int -> [(k, [(Clause, env)])] -> Either String (Maybe (k, (Clause, Value), (Clause, Value)))
firstConflict evaluate bits points = go points
  where
    go [] = Right Nothing
    go ((p, applying) : rest) = do
      results <- mapM (\(c, env) -> (,) c <$> evaluate env (clauseOutcome c)) applying
      differing <- pairs results
      case differing of
        Just (a, b) -> Right (Just (p, a, b))
        Nothing -> go rest
    pairs [] = Right Nothing
    pairs (a@(_, va) : rest) = do
      found <- firstM (\b@(_, vb) -> (\same -> if same then Nothing else Just (a, b)) <$> equalValues bits va vb) rest
      case found of
        Just pair -> Right (Just pair)
        Nothing -> pairs rest
    firstM _ [] = Right Nothing
    firstM f (x : xs) = f x >>= maybe (firstM f xs) (Right . Just)

-- | The proposition that a clause covers an input given as arguments' values.
coveredBy :: Clause -> [Expr] -> Proposition
coveredBy c point = foldr (Quantified ForSome) body (clauseInputs c)
  where
    bool = scalarType "Bool"
    origin = GeneratedFrom (propertyId (clauseLaw c))
    true = Expr bool (Constant (SBool True)) origin
    body = Conjunction ([Equation (Structural bool) g true | g <- clauseGuards c] ++
      [Equation (Structural (expressionType a)) a p | (a, p) <- zip (clauseArguments c) point])

-- | Every input of a list of quantifiers, each in its type and refinements,
-- or Left when one is not finite within the limit. The product is cut off
-- before refinements are evaluated, so a large domain costs nothing.
enumerate :: Context -> Int -> [Quantifier] -> Either String [[(Id, Value)]]
enumerate ctx limit = enumerateFrom ctx limit []

-- | As enumerate, extending inputs already known.
enumerateFrom :: Context -> Int -> [(Id, Value)] -> [Quantifier] -> Either String [[(Id, Value)]]
enumerateFrom ctx limit known = go [known]
  where
    go envs [] = Right envs
    go envs (q : rest) = do
      let binder = quantifiedBinder q
      values <- finiteValuesWithRegistry (contextRegistry ctx) (contextBits ctx) limit (binderType binder) >>= maybe (Left "not finite") Right
      if length envs * length values > limit then Left "too large" else do
        extended <- fmap concat $ mapM (\env -> fmap concat $ mapM (\v -> do
          let env' = env ++ [(binderId binder, v)]
          keep <- allM (truthIn ctx env') (quantifiedPredicates q)
          pure [env' | keep]) values) envs
        go extended rest

-- | f's inputs: its arguments' types, then its preconditions.
domain :: Context -> Int -> Program -> Id -> Either String [[(Id, Value)]]
domain ctx limit program f = do
  binders <- maybe (Left "f has no arguments to enumerate") Right (arguments program f)
  points <- enumerate ctx limit [Quantifier b [] [] | b <- binders]
  let contracts = [c | u <- programUnits program, c <- unitContracts u, contractDeclaration c == f]
      admitted env = allM id' [ truthIn ctx (zip (map binderId (contractArguments c)) (map snd env)) p
                              | c <- contracts, p <- contractPreconditions c ]
      id' = id
  fmap concat (mapM (\env -> (\keep -> [env | keep]) <$> admitted env) points)

arguments :: Program -> Id -> Maybe [Binder]
arguments program f = case [d | u <- programUnits program, d <- unitDefinitions u, declarationId (definitionDeclaration d) == f] of
  d : _ -> Just (definitionArguments d)
  [] -> case [declarationType d | u <- programUnits program, d <- unitDeclarations u, declarationId d == f] of
    ty : _ -> Just [Binder (Id (idText f ++ "::argument::" ++ show i)) ("argument " ++ show (i + 1)) t | (i, t) <- zip [0 :: Int ..] (argumentTypes ty)]
    [] -> Nothing
  where
    argumentTypes (Arrow a b) = a : argumentTypes b
    argumentTypes _ = []

parameterNames :: Program -> Id -> [String]
parameterNames program f = maybe [] (map binderName) (arguments program f)

shown :: [String] -> [Value] -> String
shown names values = intercalate ", " [name ++ " = " ++ showValue v | (name, v) <- zip (names ++ repeat "input") values]

showValue :: Value -> String
showValue (ScalarValue s) = prettyScalar s
showValue (DataValue _ tag []) = label tag
showValue (DataValue _ tag fields) = "(" ++ unwords (label tag : map showValue fields) ++ ")"
showValue (PresenceValue _ Nothing) = "absent"
showValue (PresenceValue _ (Just v)) = showValue v

label :: Id -> String
label = reverse . takeWhile (/= ':') . reverse . idText
