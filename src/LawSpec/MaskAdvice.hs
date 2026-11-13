-- | A field shown as digest is hidden from a reader and not from someone
-- who can guess its value: a digest takes no key, so every candidate can be
-- hashed and compared. Where a field's own restriction leaves few enough
-- candidates to try them all, the author is told, and pointed at the keyed
-- hash and at hiding the field. This is advice: nothing is refused, since a
-- digest of such a field can still be what its author means (a status shown
-- so that equal values line up, say). ref:DEC-masking
module LawSpec.MaskAdvice
  ( EnumerableDigest(..), enumerableDigests, enumerableDigestLimit, enumerableDigestRule
  , enumerableDigestMessage, enumerableDigestSuggestion, candidateBound ) where

import Data.Maybe (catMaybes)
import LawSpec.Common (Location, Span(..))
import LawSpec.Model
import LawSpec.Regex (Regex(..), parseRegex)

-- | A digest field whose restriction allows no more values than the limit.
data EnumerableDigest = EnumerableDigest
  { digestUnit :: String, digestRecord :: String, digestField :: String
  , digestCandidates :: Integer, digestAt :: Location
  } deriving (Eq, Show)

-- | The advice rule's name, as `advise` reports it.
enumerableDigestRule :: String
enumerableDigestRule = "enumerable-digest"

-- | The most candidate values a field may have and still be told about:
-- 2^64. Exhaustive searches of 2^64 have been carried out in public (a
-- 64-bit block cipher key in 2002, a SHA-1 collision of about 2^63 work in
-- 2017), so a value drawn from no more than that is not protected by a
-- public hash of it, however fast or slow the hash. Above it the answer
-- depends on who is searching and for how long, which a compiler cannot
-- know, so it says nothing.
enumerableDigestLimit :: Integer
enumerableDigestLimit = 2 ^ (64 :: Int)

-- | The digest fields of a unit's records that the limit covers.
enumerableDigests :: Unit -> [EnumerableDigest]
enumerableDigests unit =
  [ EnumerableDigest (unitName unit) (contractRecord contract) label bound (spanStart (dataTypeSpan declaration))
  | contract <- recordContracts unit
  , (label, MaskDigest _) <- contractMasks contract
  , declaration <- dataTypes unit, dataTypeName declaration == contractRecord contract
  , constructor <- dataTypeConstructors declaration
  , (field, ty) <- dataConstructorFields constructor, field == label
  , Just bound <- [candidateBound ty], bound <= enumerableDigestLimit ]

-- | An upper bound on the texts a field's type admits, where its
-- restriction gives one no greater than the limit: the least of the bounds
-- its conjuncts give. A regex bounds them by its shape, a list of literals
-- by its length, a length bound by the texts of that length, and an
-- equation by one. Every count is of at least the texts admitted, never
-- fewer, so a field that is reported really has no more candidates.
candidateBound :: Type -> Maybe Integer
candidateBound ty = case ty of
  Refined binder inner (Just predicate) ->
    least (catMaybes (candidateBound inner : map (conjunctBound binder) (conjuncts predicate)))
  Refined _ inner Nothing -> candidateBound inner
  _ -> Nothing
  where
    least bounds = if null bounds then Nothing else Just (minimum bounds)
    conjuncts expression = case unlocated expression of
      Binary "&&" left right -> conjuncts left ++ conjuncts right
      other -> [other]

conjunctBound :: String -> Expr -> Maybe Integer
conjunctBound binder predicate = case predicate of
  Apply (Apply (Var "prelude.regexMatches") pattern) value
    | subject value, StringLit source <- unlocated pattern, Right regex <- parseRegex source -> regexBound regex
  Apply (Apply (Var "prelude.member") value) items
    | subject value, ListLit literals <- unlocated items -> Just (fromIntegral (length literals))
  Binary op left right
    | subject left, literal right -> equation op
    | subject right, literal left -> equation op
    | lengthOf left, Number count <- unlocated right -> lengths op count
    | lengthOf right, Number count <- unlocated left -> lengths (mirrored op) count
  _ -> Nothing
  where
    subject value = unlocated value == Var binder
    literal value = case unlocated value of
      StringLit _ -> True
      _ -> False
    lengthOf value = case unlocated value of
      Apply function argument -> unlocated function == Var "prelude.length" && subject argument
      _ -> False
    mirrored op = maybe op id (lookup op [("<", ">"), ("<=", ">="), (">", "<"), (">=", "<=")])
    equation op = if op == "==" then Just 1 else Nothing
    lengths op count = case op of
      "==" -> power scalarValues count
      "<=" -> total [power scalarValues size | size <- [0 .. count]]
      "<" -> total [power scalarValues size | size <- [0 .. count - 1]]
      _ -> Nothing

-- | The Unicode scalar values: what one character of a text may be.
scalarValues :: Integer
scalarValues = 0x110000 - 0x800

-- | Counts above the limit are not kept: they would only grow.
capped :: Integer -> Maybe Integer
capped count = if count > enumerableDigestLimit then Nothing else Just count

power :: Integer -> Integer -> Maybe Integer
power base exponent
  | exponent <= 0 = Just 1
  | base <= 1 = Just base
  | exponent > 64 = Nothing
  | otherwise = capped (base ^ exponent)

total :: [Maybe Integer] -> Maybe Integer
total counts = sequence counts >>= capped . sum

-- | An upper bound on the texts a regex matches: a class by its characters,
-- a sequence by the product of its parts, alternatives by their sum, and a
-- repetition by the sum over its counts. Two ways to match one text count
-- twice, which keeps the bound an upper one.
regexBound :: Regex -> Maybe Integer
regexBound regex = case regex of
  Characters negated items
    | negated || any fst items -> Just scalarValues
    | otherwise -> Just (min scalarValues (sum [fromIntegral (high - low + 1) | (_, ranges) <- items, (low, high) <- ranges]))
  Sequence parts -> foldl (\count part -> do { a <- count; b <- regexBound part; capped (a * b) }) (Just 1) parts
  Alternatives choices -> total (map regexBound choices)
  Repeat body low high -> do
    count <- regexBound body
    case high of
      Just most -> total [power count (fromIntegral turns) | turns <- [low .. most]]
      Nothing | count == 0 -> Just 1
              | otherwise -> Nothing

-- | What the author is told, in `advise` and as a compile warning.
enumerableDigestMessage :: EnumerableDigest -> String
enumerableDigestMessage found =
  digestRecord found ++ "." ++ digestField found ++ " is shown as digest, and its restriction allows " ++ counted (digestCandidates found) ++
  ": a digest takes no key, so whoever reads one can hash every value the field may hold and find which it was. " ++
  "Show the field as hash, which is keyed, or as hidden; keep digest where the value is not a secret from those readers."
  where
    counted count
      | count == 1 = "one value"
      | count < 1000000 = "at most " ++ show count ++ " values"
      | otherwise = "at most about 2^" ++ show (bits count) ++ " values"
    bits count = length (takeWhile (> 1) (iterate (`div` 2) count))

-- | The change the advice proposes.
enumerableDigestSuggestion :: EnumerableDigest -> String
enumerableDigestSuggestion found = digestField found ++ " shown as hash"
