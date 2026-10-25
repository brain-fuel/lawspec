-- | Complete finite and bounded logical search lower to ordinary typed terms, shared by
-- the reference evaluator and every native target. The authoritative law keeps
-- its scoped proposition; an execution plan contains this checked expansion.
module LawSpec.Core.Quantification
  ( lowerFiniteProposition, lowerWitnessProposition, lowerWitnessProof
  , lowerSearchProposition, lowerSearchProof
  , lowerFinitePropositionCandidates, lowerWitnessPropositionCandidates
  , lowerSearchPropositionCandidates ) where

import Control.Monad (unless)
import LawSpec.Common (Quantification(..))
import LawSpec.Core
import LawSpec.Scalar (Scalar(..))
import Control.Monad.State.Strict (StateT, evalStateT, get, put, lift)
import Data.List (intercalate)
import LawSpec.Core.Search (Candidate(..), applyCandidate)

lowerFiniteProposition :: (Quantifier -> Either String (Maybe [Expr])) -> Int -> Id -> Proposition -> Either String Proposition
lowerFiniteProposition domain = lowerFinitePropositionCandidates (candidateDomain domain)

candidateDomain :: (Quantifier -> Either String (Maybe [Expr]))
  -> Quantifier -> Either String (Maybe [Candidate])
candidateDomain domain quantifier = fmap (fmap (map Candidate)) (domain quantifier)

lowerFinitePropositionCandidates :: (Quantifier -> Either String (Maybe [Candidate]))
  -> Int -> Id -> Proposition -> Either String Proposition
lowerFinitePropositionCandidates domain limit identity proposition
  | not (logical proposition) = Right proposition
  | otherwise = do
      (claim,_) <- walk proposition
      pure (Equation (Structural bool) claim (constant True))
  where
    origin = GeneratedFrom identity
    bool = scalarType "Bool"
    constant value = Expr bool (Constant (SBool value)) origin
    known (Expr _ (Constant (SBool value)) _) = Just value
    known _ = Nothing
    negate' value = maybe (Expr bool (Unary Not value) origin) (constant . not) (known value)
    binary op a b = case (op,known a) of
      (And,Just False) -> constant False
      (And,Just True) -> b
      (Or,Just True) -> constant True
      (Or,Just False) -> b
      _ -> Expr bool (ShortCircuit op a b) origin
    conjunction = foldr (binary And) (constant True)
    checked cost = unless (cost <= toInteger limit)
      (Left "quantifier-search-incomplete: complete finite search exceeds the exhaustive limit")
    walk (Equation evidence a b) = pure (case (known a,known b) of
      (Just x,Just y) -> constant (x == y)
      _ -> Expr bool (Binary Equal evidence a b) origin,1)
    walk (Implication guard body) = do
      if known guard == Just False then pure (constant True,1) else do
        (claim,cost) <- walk body
        pure (binary Or (negate' guard) claim,cost)
    walk (Conjunction bodies) = walkConjunction bodies
    walk (Negation body) = do
      (claim,cost) <- walk body
      pure (negate' claim,cost)
    walk (Quantified kind quantifier body) = do
      let binder = quantifiedBinder quantifier
      available <- domain quantifier
      values <- maybe (Left ("quantifier-search-incomplete: no complete finite domain for " ++
        binderName binder ++ " of type " ++ show (binderType binder))) Right available
      -- An empty outer domain decides the proposition even when a nested
      -- domain is infinite. No witness or counterexample is fabricated.
      if null values then pure (constant (kind == ForEvery),1) else do
        (claim,cost) <- walk body
        let total = toInteger (length values) * max 1 cost
        checked total
        let restriction = conjunction (quantifiedPredicates quantifier)
            required = case kind of
              ForEvery -> binary Or (negate' restriction) claim
              ForSome -> binary And restriction claim
            code = scalarType "Int8"
            outcome n = Expr code (Constant (SInteger "Int8" n)) origin
            decision = Expr code (If required (outcome 1) (outcome (-1))) origin
            searched = candidateLoop origin True (kind == ForEvery) binder decision values
        pure (Expr bool (Binary Equal (Numeric (scalarType "Integer")) searched (outcome 1)) origin,total)
    walkConjunction [] = pure (constant True,0)
    walkConjunction (body:rest) = do
      (claim,cost) <- walk body
      if known claim == Just False then pure (claim,cost) else do
        (remaining,more) <- walkConjunction rest
        checked (cost + more)
        pure (binary And claim remaining,cost + more)
    logical (Negation _) = True
    logical (Quantified _ _ _) = True
    logical (Implication _ body) = logical body
    logical (Conjunction bodies) = any logical bodies
    logical _ = False

-- | A sufficient proof goal, rather than a Boolean interpretation of a failed
-- search. Positive existence may use a checked candidate. Negative existence
-- needs complete finite coverage. Negation reverses the requested polarity.
-- These are ordinary typed terms for the existing contract prover; execution
-- continues to use the three-outcome plan above.
lowerWitnessProof :: (Quantifier -> Either String (Maybe [Expr])) -> Int -> Id
  -> [WitnessChoice] -> Proposition -> Either String Proposition
lowerWitnessProof domain limit = lowerSearchProof domain (\_ _ -> pure []) limit limit

lowerSearchProof :: (Quantifier -> Either String (Maybe [Expr]))
  -> (Quantifier -> Proposition -> Either String [Candidate]) -> Int -> Int -> Id
  -> [WitnessChoice] -> Proposition -> Either String Proposition
lowerSearchProof domain search limit searchBudget identity choices proposition = do
  (claim,_) <- derive True proposition
  pure (Equation (Structural bool) claim (constant True))
  where
    origin = GeneratedFrom identity
    bool = scalarType "Bool"
    constant value = Expr bool (Constant (SBool value)) origin
    negate' value = case expressionNode value of
      Constant (SBool b) -> constant (not b)
      _ -> Expr bool (Unary Not value) origin
    binary op a b = case (op,expressionNode a) of
      (And,Constant (SBool False)) -> constant False
      (And,Constant (SBool True)) -> b
      (Or,Constant (SBool True)) -> constant True
      (Or,Constant (SBool False)) -> b
      _ -> Expr bool (ShortCircuit op a b) origin
    aggregate all = foldr (binary (if all then And else Or)) (constant all)
    derive desired (Equation evidence a b) =
      let equality = if expressionType a == bool then case (expressionNode a,expressionNode b) of
            (_,Constant (SBool True)) -> a
            (Constant (SBool True),_) -> b
            (_,Constant (SBool False)) -> negate' a
            (Constant (SBool False),_) -> negate' b
            _ -> Expr bool (Binary Equal evidence a b) origin
          else Expr bool (Binary Equal evidence a b) origin
      in pure (if desired then equality else negate' equality,1)
    derive desired (Negation body) = derive (not desired) body
    derive desired (Implication condition body) = do
      (claim,cost) <- derive desired body
      pure (if desired then binary Or (negate' condition) claim else binary And condition claim,cost)
    derive desired (Conjunction bodies) = do
      results <- mapM (derive desired) bodies
      pure (aggregate desired (map fst results),sum (map snd results))
    derive desired (Quantified kind q body) = do
      let binder = quantifiedBinder q
          universal = kind == ForEvery
          restriction = aggregate True (quantifiedPredicates q)
          with value claim = Expr bool (Let binder value claim) origin
      available <- domain q
      if available == Just [] then pure (constant (desired == universal),1) else do
        (claim,cost) <- derive desired body
        let total = maybe (toInteger limit + 1) ((max 1 cost *) . toInteger . length) available
            all = desired == universal
            required = if all then binary Or (negate' restriction) claim else binary And restriction claim
        complete <- if total > toInteger limit then pure (constant False) else case available of
          Nothing -> pure (constant False)
          Just values -> pure (aggregate all (map (\value -> with value required) values))
        candidates <- if all then pure [] else do
          sampled <- if available /= Nothing && total <= toInteger limit then pure [] else search q body
          let configured = [Candidate (witnessValue w) | w <- choices,witnessTarget w == binderId binder]
          pure (take (fromInteger (max 0 (toInteger searchBudget `quot` max 1 cost))) (configured ++ sampled))
        let constructive = aggregate False [applyCandidate candidate (\value -> with value required) (constant False) |
              candidate <- candidates]
        pure (binary Or constructive complete,if null candidates then total else
          min total (toInteger (length candidates) * max 1 cost))
-- | Partial search has three outcomes. A candidate proves existence only when
-- its restriction and body hold; candidate failure supplies no absence fact.
-- Negation swaps true/false and leaves incomplete unchanged. Ordinary typed
-- lets and conditionals evaluate each visited candidate exactly once.
lowerWitnessProposition :: (Quantifier -> Either String (Maybe [Expr])) -> Int -> Id
  -> [WitnessChoice] -> Proposition -> Either String Proposition
lowerWitnessProposition domain limit identity choices proposition
  = lowerWitnessPropositionCandidates (candidateDomain domain) limit identity choices proposition

lowerWitnessPropositionCandidates :: (Quantifier -> Either String (Maybe [Candidate]))
  -> Int -> Id -> [WitnessChoice] -> Proposition -> Either String Proposition
lowerWitnessPropositionCandidates domain limit identity choices proposition
  | null choices = lowerFinitePropositionCandidates domain limit identity proposition
  | otherwise = lowerSearchPropositionCandidates domain (\_ _ -> pure []) limit limit identity choices proposition

lowerSearchProposition :: (Quantifier -> Either String (Maybe [Expr]))
  -> (Quantifier -> Proposition -> Either String [Candidate]) -> Int -> Int -> Id
  -> [WitnessChoice] -> Proposition -> Either String Proposition
lowerSearchProposition domain = lowerSearchPropositionCandidates (candidateDomain domain)

lowerSearchPropositionCandidates :: (Quantifier -> Either String (Maybe [Candidate]))
  -> (Quantifier -> Proposition -> Either String [Candidate]) -> Int -> Int -> Id
  -> [WitnessChoice] -> Proposition -> Either String Proposition
lowerSearchPropositionCandidates domain search limit searchBudget identity choices proposition
  | not (hasLogicalQuantifier proposition) = lowerFinitePropositionCandidates domain limit identity proposition
  | otherwise = flip evalStateT (0 :: Int) $ do
      (decision,_) <- walk proposition
      claim <- bind decision $ \outcome -> pure (branch (is 1 outcome) (boolean True)
        (branch (is (-1) outcome) (boolean False) incomplete))
      pure (Equation (Structural bool) claim (boolean True))
  where
    origin = GeneratedFrom identity
    bool = scalarType "Bool"
    code = scalarType "Int8"
    boolean value = Expr bool (Constant (SBool value)) origin
    outcome value = Expr code (Constant (SInteger "Int8" value)) origin
    known value = case expressionNode value of Constant (SInteger "Int8" n) -> Just n; _ -> Nothing
    branch condition yes no = case expressionNode condition of
      Constant (SBool True) -> yes
      Constant (SBool False) -> no
      _ -> Expr (expressionType yes) (If condition yes no) origin
    is n value = maybe (Expr bool (Binary Equal (Numeric (scalarType "Integer")) value (outcome n)) origin)
      (boolean . (== n)) (known value)
    bind :: Expr -> (Expr -> StateT Int (Either String) Expr) -> StateT Int (Either String) Expr
    bind value body | Just _ <- known value = body value
    bind value body = do
      index <- get
      put (index + 1)
      let binder = Binder (Id (idText identity ++ "::logical::decision" ++ show index)) ("decision" ++ show index) code
      result <- body (Expr code (Local (binderId binder)) origin)
      pure (Expr (expressionType result) (Let binder value result) origin)
    combine universal a b = bind a $ \x -> do
      remainder <- bind b $ \y -> pure (branch (is decisive y) (outcome decisive)
        (branch (is neutral x) y (outcome 0)))
      pure (branch (is decisive x) (outcome decisive) remainder)
      where decisive = if universal then -1 else 1
            neutral = negate decisive
    aggregate _ [value] = pure value
    aggregate universal [] = pure (outcome (if universal then 1 else -1))
    aggregate universal values = do
      let (first,rest) = splitAt (length values `quot` 2) values
      left <- aggregate universal first
      right <- aggregate universal rest
      combine universal left right
    restriction q = foldr (\a b -> Expr bool (ShortCircuit And a b) origin) (boolean True) (quantifiedPredicates q)
    incomplete = Expr bool (Helper IncompleteSearch [Expr (scalarType "Text")
      (Constant (SSequence "Text" (map fromEnum ("quantifier-search-incomplete: bounded search (at most " ++
        show searchBudget ++ " candidate evaluations per scoped branch) with " ++
        (if null choices then "default or selected harness strategies" else "selected witnesses for " ++
          intercalate ", " ["definition." ++ intercalate "." (witnessLexicalPath w) | w <- choices]) ++
        " did not decide the proposition; failed candidates and bounded misses do not prove nonexistence")))) origin]) origin
    walk :: Proposition -> StateT Int (Either String) (Expr,Integer)
    walk (Equation evidence a b) = pure (branch (Expr bool (Binary Equal evidence a b) origin) (outcome 1) (outcome (-1)),1)
    walk (Implication condition body) = do
      (decision,cost) <- walk body
      pure (branch condition decision (outcome 1),cost)
    walk (Conjunction bodies) = do
      results <- mapM walk bodies
      combined <- aggregate True (map fst results)
      pure (combined,sum (map snd results))
    walk (Negation body) = do
      (decision,cost) <- walk body
      reversed <- bind decision $ \x -> pure (branch (is 1 x) (outcome (-1)) (branch (is (-1) x) (outcome 1) (outcome 0)))
      pure (reversed,cost)
    walk (Quantified kind q body) = do
      let binder = quantifiedBinder q
      available <- lift (domain q)
      if available == Just [] then pure (outcome (if kind == ForEvery then 1 else -1),1) else do
        (decision,cost) <- walk body
        let total = maybe (toInteger limit + 1) ((max 1 cost *) . toInteger . length) available
            required = branch (restriction q) decision (outcome (if kind == ForEvery then 1 else -1))
        complete <- if total > toInteger limit then pure (outcome 0) else case available of
          Nothing -> pure (outcome 0)
          Just terms -> pure (candidateLoop origin True (kind == ForEvery) binder required terms)
        sampled <- if available /= Nothing && total <= toInteger limit then pure [] else lift (search q body)
        let configured = [Candidate (witnessValue w) | w <- choices,witnessTarget w == binderId binder]
            candidates = take (fromInteger (max 0 (toInteger searchBudget `quot` max 1 cost))) (configured ++ sampled)
        let attempted = candidateLoop origin False (kind == ForEvery) binder required candidates
        let decisive = if kind == ForEvery then -1 else 1
        result <- bind attempted $ \x -> pure (branch (is decisive x) (outcome decisive) complete)
        pure (result,if null candidates then total else min total (toInteger (length candidates) * max 1 cost))

-- A guarded or effectful candidate is selected before it is evaluated. Its
-- value computation appears once in an indexed choice; the law body appears
-- once after the successful choice. Rejected filters never run the conversion
-- or body, and a decisive result never evaluates a later candidate.
candidateLoop :: Origin -> Bool -> Bool -> Binder -> Expr -> [Candidate] -> Expr
candidateLoop origin pureDomain universal binder required candidates
  | null candidates = outcome neutral
  | pureDomain || all literal candidates, Just terms <- traverse plain candidates =
      Expr code (SearchElements universal (finiteTerms binder terms) binder required) origin
  | otherwise = Expr code (SearchElements universal indices index body) origin
  where
    code = scalarType "Int8"
    integer = scalarType "Integer"
    outcome n = Expr code (Constant (SInteger "Int8" n)) origin
    neutral = if universal then 1 else -1
    plain (Candidate value) = Just value
    plain _ = Nothing
    literal (Candidate (Expr _ (Constant _) _)) = True
    literal _ = False
    index = Binder (Id (idText (binderId binder) ++ "::candidate-index")) (binderName binder ++ "Index") integer
    position = Expr integer (Local (binderId index)) origin
    ordinal n = Expr integer (Constant (SInteger "Integer" n)) origin
    indices = finiteTerms index (map (ordinal . toInteger) [0..length candidates-1])
    optional = Constructor "Maybe" [TypeArgument (binderType binder)]
    absent = Expr optional (Construct (Id "Maybe::Absent") []) origin
    present value = Expr optional (Construct (Id "Maybe::Present") [value]) origin
    select _ [] = absent
    select _ [candidate] = applyCandidate candidate present absent
    select lower choices = let
      (left,right) = splitAt (length choices `quot` 2) choices
      midpoint = lower + toInteger (length left)
      condition = Expr (scalarType "Bool") (Binary Less (Numeric integer) position (ordinal midpoint)) origin
      in Expr optional (If condition (select lower left) (select midpoint right)) origin
    selected = select 0 candidates
    body = Expr code (Match selected
      [MatchCase (Id "Maybe::Absent") [] (outcome neutral),
       MatchCase (Id "Maybe::Present") [binder] required]) origin

-- | Keep the candidate body outside its domain. Consecutive constants use the
-- existing half-open range plus the final value, so a bounded maximum needs
-- no overflowing upper-plus-one constant. Other checked domains retain their
-- order as ordinary List data.
finiteTerms :: Binder -> [Expr] -> Expr
finiteTerms binder terms = case terms of
  first@(Expr ty (Constant (SInteger name start)) _) : rest
    | length rest >= 2
    , and [expressionType term == ty && expressionNode term == Constant (SInteger name expected)
           | (expected, term) <- zip [start + 1 ..] rest]
    , final : _ <- reverse rest ->
        Expr listType (Helper Append [Expr listType (Helper Range [first, final]) origin, cons final nil]) origin
  _ -> balanced (chunks terms)
  where
    origin = GeneratedFrom (binderId binder)
    listType = Constructor "List" [TypeArgument (binderType binder)]
    nil = Expr listType (Construct (Id "List::Nil") []) origin
    cons first rest = Expr listType (Construct (Id "List::Cons") [first, rest]) origin
    chunks [] = []
    chunks values = let (front,rest) = splitAt 8 values in foldr cons nil front : chunks rest
    balanced [] = nil
    balanced [value] = value
    balanced values = let (front,rest) = splitAt (length values `quot` 2) values
      in Expr listType (Helper Append [balanced front,balanced rest]) origin
