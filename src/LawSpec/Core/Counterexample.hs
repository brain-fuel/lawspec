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
  ( CounterexampleCheck(..), checkStatus, validateCounterexample, readValues, valueOf, SExpression
  ) where

import Data.Char (isDigit, isHexDigit, isSpace)
import Numeric (readHex, showHex)
import Data.Ratio (numerator, denominator)
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
  (Constructor "Rational" [], _) | Just r <- realTerm term -> Right (ScalarValue (SRational (numerator r) (denominator r)))
  (Constructor "Decimal" [], _) | Just r <- realTerm term, Just (c, e) <- decimalOf r -> Right (ScalarValue (SDecimal c e))
  (Constructor "Rational" [], _) -> Left ("Z3's value " ++ render term ++ " is not a rational number")
  (Constructor "Decimal" [], _) -> Left ("Z3's value " ++ render term ++ " is not a decimal")
  (Constructor t [], _) | t `elem` ["Float32", "Float64"], Just bits <- floatBits t term -> Right (ScalarValue (SFloat t bits))
  (Constructor "Text" [], Atom ('"' : quoted)) | not (null quoted), last quoted == '"', Just units <- stringUnits (init quoted) ->
    Right (ScalarValue (SSequence "Text" units))
  (Constructor name [], _) | isInteger name, Just n <- integerTerm term -> Right (ScalarValue (SInteger name n))
  _ -> Left ("Z3's value " ++ render term ++ " cannot be read back as " ++ show ty)
  where
    -- A Real as Z3 prints it: 2.5, (- 2.0), (/ 1.0 3.0); never root-obj.
    realTerm t = case t of
      Atom text | (whole, rest) <- span isDigit text, not (null whole) -> case rest of
        "" -> Just (fromInteger (read whole))
        '.' : fraction | all isDigit fraction -> Just (fromInteger (read (whole ++ fraction)) / 10 ^ length fraction)
        _ -> Nothing
      List [Atom "-", inner] -> negate <$> realTerm inner
      List [Atom "/", n, d] -> do
        a <- realTerm n
        b <- realTerm d
        if b == 0 then Nothing else Just (a / b)
      List [Atom "to_real", inner] -> realTerm inner
      _ -> Nothing
    decimalOf :: Rational -> Maybe (Integer, Integer)
    decimalOf r = case [k | k <- [0 .. 64], denominator (r * 10 ^ k) == 1] of
      k : _ -> Just (numerator (r * 10 ^ k), negate k)
      [] -> Nothing
    -- (fp #b0 #b01111111 #b000...), or (_ +zero 8 24), (_ NaN 11 53), ...
    floatBits t value = do
      let (e, m) = if t == "Float32" then (8, 24) else (11, 53 :: Int)
          width = 1 + e + m - 1
          hex bitsText = let n = foldl (\acc c -> acc * 2 + (if c == '1' then 1 else 0)) (0 :: Integer) bitsText
                             h = showHex n ""
                         in replicate (width `div` 4 - length h) '0' ++ h
          ones k = replicate k '1'
          zeros k = replicate k '0'
      case value of
        List [Atom "fp", Atom sign', Atom exponent'', Atom mantissa']
          | Just sign <- bitsOf sign', Just exponent' <- bitsOf exponent'', Just mantissa <- bitsOf mantissa'
          , length sign == 1 && length exponent' == e && length mantissa == m - 1 -> Just (hex (sign ++ exponent' ++ mantissa))
        List [Atom "_", Atom special, Atom _, Atom _] -> case special of
          "+zero" -> Just (hex ("0" ++ zeros e ++ zeros (m - 1)))
          "-zero" -> Just (hex ("1" ++ zeros e ++ zeros (m - 1)))
          "+oo" -> Just (hex ("0" ++ ones e ++ zeros (m - 1)))
          "-oo" -> Just (hex ("1" ++ ones e ++ zeros (m - 1)))
          "NaN" -> Just (hex ("0" ++ ones e ++ "1" ++ zeros (m - 2)))
          _ -> Nothing
        _ -> Nothing
    -- A bit-vector literal, #b0101 or #x5.
    bitsOf text = case text of
      '#' : 'b' : digits | all (`elem` ("01" :: String)) digits -> Just digits
      '#' : 'x' : digits | all isHexDigit digits -> Just (concatMap nibble digits)
      _ -> Nothing
    nibble c = let n = fst (head (readHex [c])) :: Int in [if (n `div` k) `mod` 2 == 1 then '1' else '0' | k <- [8, 4, 2, 1]]
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
  -- A string literal, where "" is a quote inside it.
  '"' : rest -> let (literal, more) = stringLiteral rest in ('"' : literal ++ "\"") : tokens more
  '(' : rest -> "(" : tokens rest
  ')' : rest -> ")" : tokens rest
  rest -> let (atom, more) = break (\c -> isSpace c || c == '(' || c == ')') rest in atom : tokens more

stringLiteral :: String -> (String, String)
stringLiteral text = case text of
  '"' : '"' : rest -> let (literal, more) = stringLiteral rest in ('"' : '"' : literal, more)
  '"' : rest -> ("", rest)
  c : rest -> let (literal, more) = stringLiteral rest in (c : literal, more)
  [] -> ("", "")

-- | An SMT string literal's code points: "" is a quote and \u{...} a code
-- point, as Z3 prints them.
stringUnits :: String -> Maybe [Int]
stringUnits text = case text of
  [] -> Just []
  '"' : '"' : rest -> (34 :) <$> stringUnits rest
  '\\' : 'u' : '{' : rest | (digits, '}' : more) <- span isHexDigit rest, not (null digits), length digits <= 5 ->
    (fst (head (readHex digits)) :) <$> stringUnits more
  c : rest -> (fromEnum c :) <$> stringUnits rest

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
