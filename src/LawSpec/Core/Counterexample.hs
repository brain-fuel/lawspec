-- | Z3 is an untrusted search tool for counterexamples. When a task's
-- negation is satisfiable, the host runs its counterexample query
-- (Core.Smt) and asks Z3 for the values of the law's outer inputs. This
-- module reads those values back and re-checks the law at them with the
-- reference evaluator, the one behind exhaustively-checked and refuted:
--
-- * refuted: the evaluator finds the law false, or undefined, there;
-- * model-not-confirmed: the evaluator finds the law true there, or the
--   values lie outside the law's domain, so the translation or the solver
--   is wrong;
-- * incomplete: the rest of the law has quantifiers of its own, or a value
--   cannot be read back.
--
-- This follows Why3's --check-ce and SPARK's counterexample checking, which
-- run the prover's model through runtime assertion checking and report only
-- confirmed ones. ref:DEC-validated-counterexamples
module LawSpec.Core.Counterexample
  ( CounterexampleCheck(..), checkStatus, validateCounterexample, readValues
  ) where

import Data.Char (isDigit, isSpace)
import Data.List (isPrefixOf)
import LawSpec.Core
import LawSpec.Common (Generation(..), Quantification(..))
import LawSpec.Core.Definitions (prepareHookedDefinitions)
import LawSpec.Core.Quantification (lowerFiniteProposition)
import LawSpec.Core.QuantifierDomain (finiteQuantifierTerms)
import LawSpec.Testing (finiteValuesWithRegistry)
import LawSpec.Core.Eval (evaluateValue, evaluateValueProposition, validateValueWithContracts)
import LawSpec.Core.Smt (CounterexampleQuery(..), ProofTask(..), Catalog, catalog, instantiate, outerQuantifiers)
import Control.Monad (unless, zipWithM)
import qualified Data.Map.Strict as M
import LawSpec.Core.Types (TypeRegistry, makeRegistry)
import LawSpec.Core.Value (Value(..))
import LawSpec.Scalar (Scalar(..), isInteger)

data CounterexampleCheck
  = Refuted [(Quantifier, Value)] String
  | ModelNotConfirmed [(Quantifier, Value)] String
  | CheckIncomplete String
  deriving (Eq, Show)

checkStatus :: CounterexampleCheck -> String
checkStatus Refuted{} = "refuted"
checkStatus ModelNotConfirmed{} = "model-not-confirmed"
checkStatus CheckIncomplete{} = "incomplete"

-- | The values Z3 gave for a task's counterexample query (the text of its
-- get-value answer), checked against the law.
validateCounterexample :: Program -> ProofTask -> String -> CounterexampleCheck
validateCounterexample program task answer = case taskCounterexample task of
  Left reason -> CheckIncomplete ("this task has no counterexample query: " ++ reason)
  Right query -> case [p | u <- programUnits program, unitId u == taskOwner task, p <- unitProperties u, propertyId p == taskLaw task] of
    [law] -> either CheckIncomplete id $ do
      registry <- makeRegistry (programDataDeclarations program)
      hooked <- either (Left . concatMap show) Right (prepareHookedDefinitions program)
      named <- readValues answer
      let types = catalog program
      values <- mapM (\(name, q) -> maybe (Left ("Z3 gave no value for " ++ binderName (quantifiedBinder q)))
        (valueOf types (binderType (quantifiedBinder q))) (lookup name named)) (counterexampleInputs query)
      let inputs = zip (map snd (counterexampleInputs query)) values
          invoke = hooked (\_ _ -> Nothing)
          bits = programMachineBits program
          (_, rest) = outerQuantifiers law
          limit = exhaustiveLimit (propertyGeneration law)
          finite = lowerFiniteProposition (finiteQuantifierTerms bits limit (finiteValuesWithRegistry registry bits limit))
            limit (propertyId law)
      pure (check registry bits invoke inputs rest finite)
    _ -> CheckIncomplete "the task's law is not in the program"
  where
    -- Quantifiers inside the rest of the law are searched completely when
    -- their domains are finite and small enough; otherwise the values stay
    -- unconfirmed.
    check registry bits invoke inputs rest finite =
      case foldl (admit registry bits invoke) (Right []) inputs of
        Left outcome -> outcome
        Right env -> case (if hasLogicalQuantifier rest then finite rest else Right rest) of
          Left message -> CheckIncomplete ("the rest of the law has quantifiers of its own that cannot be searched completely ("
            ++ message ++ "); Z3's values for its outer inputs are not confirmed")
          Right claim -> case evaluateValueProposition registry bits invoke env claim of
              Right False -> Refuted inputs "the reference evaluator finds the law false at these values"
              Right True -> ModelNotConfirmed inputs
                "the reference evaluator finds the law true at Z3's values; the translation or the solver is wrong"
              Left message | "quantifier-search-incomplete:" `isPrefixOf` message -> CheckIncomplete message
                           | "external call" `isPrefixOf` message -> CheckIncomplete message
                           | otherwise -> Refuted inputs ("the law is undefined at these values: " ++ message)
    -- Each value must lie in its type and satisfy its refinements, in order,
    -- or the model is not a counterexample of this law.
    admit registry bits invoke known (q, v) = case known of
      Left outcome -> Left outcome
      Right env -> do
        let binder = quantifiedBinder q
            env' = env ++ [(binderId binder, v)]
            outside why = Left (ModelNotConfirmed [] ("Z3's value for " ++ binderName binder ++ " is outside " ++ why))
        case validateValueWithContracts registry bits (binderType binder) v of
          Left _ -> outside "its type"
          Right _ -> pure ()
        holds <- mapM (\p -> case evaluateValue registry bits invoke env' p of
          Right (ScalarValue (SBool b)) -> Right b
          Right _ -> Left (CheckIncomplete "a refinement did not evaluate to a Boolean")
          Left message -> Left (CheckIncomplete ("a refinement could not be evaluated: " ++ message))) (quantifiedPredicates q)
        if and holds then Right env' else outside "the law's domain"

-- | A value of a quantified carrier, from Z3's term. A datum is its
-- constructor's quoted symbol (Type#Constructor) applied to its fields.
valueOf :: Catalog -> Type -> SExpression -> Either String Value
valueOf types ty term = case (ty, term) of
  (Constructor name arguments, _) | Just declaration <- M.lookup name types -> do
    let (symbol, fields) = case term of
          List (Atom s : xs) -> (s, xs)
          Atom s -> (s, [])
          _ -> ("", [])
        tag = reverse (takeWhile (/= '#') (reverse (filter (/= '|') symbol)))
        table = zip (dataParameters declaration) [t | TypeArgument t <- arguments]
    c <- case [c | c <- dataConstructors declaration, constructorName c == tag] of
      c : _ -> Right c
      [] -> Left ("Z3's value " ++ render term ++ " is not a constructor of " ++ name)
    unless (length fields == length (constructorFields c)) (Left ("Z3's value " ++ render term ++ " has the wrong number of fields"))
    values <- zipWithM (\f t -> valueOf types (instantiate table (binderType f)) t) (constructorFields c) fields
    pure (DataValue ty (constructorId c) values)
  (Constructor "Bool" [], Atom "true") -> Right (ScalarValue (SBool True))
  (Constructor "Bool" [], Atom "false") -> Right (ScalarValue (SBool False))
  (Constructor "Unit" [], _) -> Right (ScalarValue (SAbsent "Unit"))
  (Constructor name [], _) | isInteger name, Just n <- integerTerm term -> Right (ScalarValue (SInteger name n))
  _ -> Left ("Z3's value " ++ render term ++ " cannot be read back as " ++ show ty)
  where
    integerTerm (Atom digits) | not (null digits), all isDigit digits = Just (read digits)
    integerTerm (List [Atom "-", inner]) = negate <$> integerTerm inner
    integerTerm _ = Nothing

data SExpression = Atom String | List [SExpression] deriving (Eq, Show)

render :: SExpression -> String
render (Atom a) = a
render (List xs) = "(" ++ unwords (map render xs) ++ ")"

-- | get-value's answer: ((name value) ...).
readValues :: String -> Either String [(String, SExpression)]
readValues answer = case parse (tokens answer) of
  Just (List pairs, []) -> mapM pair pairs
  _ -> Left "Z3's get-value answer is not a list of values"
  where
    pair (List [Atom name, term]) = Right (name, term)
    pair other = Left ("unexpected get-value entry: " ++ render other)

tokens :: String -> [String]
tokens text = case dropWhile isSpace text of
  [] -> []
  '|' : rest -> let (symbol, more) = break (== '|') rest in ('|' : symbol ++ "|") : tokens (drop 1 more)
  '(' : rest -> "(" : tokens rest
  ')' : rest -> ")" : tokens rest
  rest -> let (atom, more) = break (\c -> isSpace c || c == '(' || c == ')') rest in atom : tokens more

parse :: [String] -> Maybe (SExpression, [String])
parse ("(" : rest) = go [] rest
  where
    go acc (")" : more) = Just (List (reverse acc), more)
    go acc more = do
      (item, after) <- parse more
      go (item : acc) after
parse (")" : _) = Nothing
parse (atom : rest) = Just (Atom atom, rest)
parse [] = Nothing
