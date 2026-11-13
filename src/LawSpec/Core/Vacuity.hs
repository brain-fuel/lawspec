-- | Guards of a law's claim: the antecedents of its implications. A generated
-- case that fails a guard says nothing about what the guard protects, so the
-- compiler reads each guard three ways: as a hint for the generator of the
-- input it is about (generation is biased, the guard is still evaluated), as
-- a site whose reached consequences the generated tests count, and as the
-- subject of authoring advice. The precedent is QuickCheck's ==> with its
-- discard count and cover, Hypothesis's assume with its filter_too_much health
-- check, fast-check's pre, jetCheck's suchThat and the Why3/SPARK smoke
-- detector. ref:DEC-vacuous-outcome
module LawSpec.Core.Vacuity
  ( propositionGuards, guardCount, guardPredicates, guardedQuantifier, guardDirected
  , membership, membershipIn, memberCovers, GuardAdvice(..), guardAdvice, programGuardAdvice, lawspecText
  , reachTargets
  ) where

import Data.List (intercalate, nub)
import LawSpec.Scalar (Scalar(..))
import LawSpec.Core
import LawSpec.Core.Evidence (adapterDeclarations)

-- | The targets whose generated tests count reached consequences. On every
-- other target a guarded law's reach is reported unknown, never as measured.
reachTargets :: [String]
reachTargets = ["java", "javascript", "python", "scala", "typescript"]

-- | The guards of a claim, outermost first: the antecedent of each implication
-- reached through conjunctions and other implications. An implication under a
-- nested quantifier or a negation is part of a searched expression, not a
-- site: generated tests evaluate it many times for one case, or not at all.
propositionGuards :: Proposition -> [Expr]
propositionGuards proposition = case proposition of
  Implication guard body -> guard : propositionGuards body
  Conjunction bodies -> concatMap propositionGuards bodies
  _ -> []

-- | How many sites a law's generated tests count.
guardCount :: Property -> Int
guardCount = length . propositionGuards . propertyBody

-- | The parts of a guard joined by and.
conjuncts :: Expr -> [Expr]
conjuncts e = case expressionNode e of
  ShortCircuit And a b -> conjuncts a ++ conjuncts b
  _ -> [e]

-- | The guard conjuncts that can direct one input's generator: a regex match,
-- a call of a checked definition (which may hold one) or membership in a
-- list, about that input alone. A conjunct naming another input would make
-- the generator depend on a value drawn later. Comparisons are left out:
-- unbiased generation already satisfies them often.
guardPredicates :: Proposition -> Quantifier -> [Expr]
guardPredicates body q =
  [ part | guard <- propositionGuards body, part <- conjuncts guard
  , let free = nub (freeBinders part), free == [binderId (quantifiedBinder q)]
  , directing part ]
  where
    directing part = case expressionNode part of
      Helper RegexMatches _ -> True
      ExternalCall _ _ -> True
      _ -> membership part /= Nothing

-- | Whether a law's generators are aimed by its guards alone: no input is
-- refined, and some input has hints, which then came from guards. Emitters
-- draw such a law's inputs as they draw refined ones, among hints and
-- unbiased values, so that some cases satisfy the guard.
guardDirected :: [Quantifier] -> [[Expr]] -> Bool
guardDirected inputs hints = all (null . quantifiedPredicates) inputs && any (not . null) hints

-- | An input as generation hints see it: its refinements, then the guards
-- about it. Never used to decide which values are valid.
guardedQuantifier :: Proposition -> Quantifier -> Quantifier
guardedQuantifier body q = q { quantifiedPredicates = quantifiedPredicates q ++ guardPredicates body q }

-- | x in c as elaboration writes it (a let for the needle and the collection,
-- then not every item differs): the subject, the collection, and the list of
-- its items as an expression closed but for what the collection names.
membershipIn :: Expr -> Maybe (Expr, Expr, Expr)
membershipIn e = case expressionNode e of
  Let needle subject inner
    | Let stored collection found <- expressionNode inner
    , Unary Not every <- expressionNode found
    , AllElements items item differs <- expressionNode every
    , Binary NotEqual (Structural _) left right <- expressionNode differs
    , sort2 (local left, local right) == sort2 (Just (binderId needle), Just (binderId item))
    , binderId needle `notElem` freeBinders items ->
        Just (subject, collection, Expr (expressionType items) (Let stored collection items) (expressionOrigin e))
  _ -> Nothing
  where
    local value = case expressionNode (unconverted value) of
      Local identity -> Just identity
      _ -> Nothing
    sort2 (a, b) = if a <= b then (a, b) else (b, a)

-- | x in [e1, e2, ...]: the subject and the items of a list written out in
-- the source.
membership :: Expr -> Maybe (Expr, [Expr])
membership e = do
  (subject, collection, _) <- membershipIn e
  items <- listItems collection
  pure (subject, items)

-- | The lists an input must be a member of, each as an expression over the
-- inputs before it: a mandatory conjunct x in c of its refinement, where c
-- does not name x. Every value of the input equals an item of each list, so
-- the items of one are a complete cover of the input's domain once each is
-- checked against the whole refinement. Nothing is inferred from a
-- disjunction or from a guard. Floating-point items are left out: equal
-- floats (0.0 and -0.0) are not interchangeable.
memberCovers :: Quantifier -> [Expr]
memberCovers q =
  [ items | predicate <- quantifiedPredicates q, part <- conjuncts predicate
  , Just (subject, _, items) <- [membershipIn part]
  , expressionNode (unconverted subject) == Local current
  , current `notElem` freeBinders items
  , not (any (`elem` ["Float32", "Float64", "Complex64", "Complex128"]) (typeNames (binderType (quantifiedBinder q)))) ]
  where
    current = binderId (quantifiedBinder q)
    typeNames ty = case ty of
      Constructor name arguments -> name : concat [typeNames argument | TypeArgument argument <- arguments]
      _ -> []

unconverted :: Expr -> Expr
unconverted e = case expressionNode e of
  Convert _ _ inner -> unconverted inner
  _ -> e

-- | The items of a list built from Cons and Nil, or held as one constant.
listItems :: Expr -> Maybe [Expr]
listItems e = case expressionNode e of
  Construct (Id "List::Nil") [] -> Just []
  Construct (Id "List::Cons") [item, rest] -> (item :) <$> listItems rest
  Convert _ _ inner -> listItems inner
  _ -> Nothing

-- | One suggestion for a law whose guard generation cannot be expected to
-- satisfy, or can only because the compiler read the guard.
data GuardAdvice = GuardAdvice
  { adviceRule :: String
  , adviceInput :: String
  , adviceSuggestion :: String
  , adviceMessage :: String
  } deriving (Eq, Show)

-- | A law's guard advice within its program: adapters are the declarations
-- no unit gives a checked body.
programGuardAdvice :: Program -> Property -> [GuardAdvice]
programGuardAdvice program = guardAdvice (`elem` adapters)
  where
    adapters = [declarationId d | unit <- programUnits program, d <- adapterDeclarations unit]

-- | Advice for a law's guards. A regex or literal-list guard on a directly
-- quantified input belongs in the input's refinement, where it also narrows
-- examples, shrinking and every other reader of the domain. A guard that
-- calls an adapter on an input cannot be read by the compiler at all: only a
-- harness strategy can build values it accepts.
guardAdvice :: (Id -> Bool) -> Property -> [GuardAdvice]
guardAdvice adapter law = nub (concatMap input (propertyInputs law) ++ adapters)
  where
    body = propertyBody law
    input q = concatMap (refinable q) (guardPredicates body q)
    refinable q part
      | binderType binder == scalarType "Text"
      , Helper RegexMatches [Expr _ (Constant (SSequence _ pattern)) _, subject] <- expressionNode part
      , isInput subject =
          [suggest (name ++ " matches regex " ++ lawspecText (map toEnum pattern))]
      | Just (subject, items) <- membership part, isInput subject
      , Just literals <- mapM literal items, not (null literals) =
          [suggest (name ++ " in [" ++ intercalate ", " literals ++ "]")]
      | otherwise = []
      where
        binder = quantifiedBinder q
        name = binderName binder
        isInput value = case expressionNode (unconverted value) of
          Local identity -> identity == binderId binder
          _ -> False
        suggest predicate =
          let suggestion = if null (quantifiedPredicates q)
                then "the refined quantifier (" ++ name ++ " :: " ++ typeText (binderType binder) ++ " where " ++ predicate ++
                  ") in place of the guard `" ++ predicate ++ " implies`"
                else "adding `" ++ predicate ++ "` to the refinement of " ++ name ++ " in place of the guard `" ++ predicate ++ " implies`"
          in GuardAdvice "vacuous-guard" name suggestion
            ("Consider " ++ suggestion ++ ". A refinement is the input's domain: every generated case, example and shrunk " ++
             "counterexample satisfies it. A guard only skips the claim, and a law none of whose generated cases satisfies its guard is reported vacuous.")
    adapters =
      [ GuardAdvice "adapter-guard" name suggestion
          ("Consider " ++ suggestion ++ ". The guard calls the adapter " ++ called ++ " on " ++ name ++
           "; the compiler cannot see which values an adapter accepts, so it cannot aim generation at them, and a law none of whose generated cases satisfies its guard is reported vacuous.")
      | guard <- propositionGuards body
      , (called, arguments) <- adapterCalls guard
      , q <- propertyInputs law, binderId (quantifiedBinder q) `elem` concatMap freeBinders arguments
      , let name = binderName (quantifiedBinder q)
            suggestion = "a harness strategy that builds values of " ++ name ++ " the guard accepts (`strategy accepted :: " ++
              typeText (binderType (quantifiedBinder q)) ++ " is ... end strategy`, then `use accepted for " ++ name ++ "` under `for law` in the unit's harness)" ]
    -- Adapter calls of a guard, with their arguments. A checked definition
    -- cannot call an adapter (totality refuses it), so the call is in the
    -- guard itself.
    adapterCalls e = case expressionNode e of
      ExternalCall callee arguments ->
        [(declarationText callee, arguments) | adapter callee] ++ concatMap adapterCalls arguments
      _ -> concatMap adapterCalls (children e)
    declarationText identity = reverse (takeWhile (/= ':') (reverse (idText identity)))
    literal value = case expressionNode value of
      Constant (SSequence "Text" codes) -> Just (lawspecText (map toEnum codes))
      Constant (SInteger _ n) -> Just (show n)
      Constant (SBool b) -> Just (if b then "true" else "false")
      _ -> Nothing
    -- A declared type is named unit::type::Name in Core; the author writes Name.
    typeText ty = case ty of
      Constructor name [] -> reverse (takeWhile (/= ':') (reverse name))
      _ -> "T"

-- | A text as a LawSpec string literal.
lawspecText :: String -> String
lawspecText text = "\"" ++ concatMap escape text ++ "\""
  where
    escape '"' = "\\\""
    escape '\\' = "\\\\"
    escape '\n' = "\\n"
    escape '\t' = "\\t"
    escape c = [c]
