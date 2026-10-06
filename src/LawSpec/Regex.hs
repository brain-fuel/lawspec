-- Portable regular expressions: the subset of RE2 and ECMAScript in which a
-- pattern means the same thing in both. LawSpec checks every regex literal
-- here, at compile time, and each runtime carries a small matcher for the
-- same dialect, so a pattern matches the same texts on every target.
--
-- A regex matches a whole text, code point by code point:
--
--   * any character other than \ . ^ $ | ? * + ( ) [ ] { } matches itself;
--   * \ before one of those, or before - or /, matches it literally;
--     \n \t \r \f \v are the control characters; \d \w \s are the ASCII
--     classes [0-9], [A-Za-z0-9_] and [ \t\n\r\f\v], and \D \W \S their
--     complements;
--   * . matches any character except a newline;
--   * [...] and [^...] are classes of characters, ranges a-z and escapes;
--     a - first or last in a class is literal;
--   * (...) and (?:...) group, | separates alternatives;
--   * * + ? {n} {n,} {n,m} repeat what comes before (0 <= n <= m <= 1000).
--
-- Anchors, word boundaries, backreferences, lookaround, named groups, flags,
-- lazy quantifiers and Unicode property classes are rejected: their meaning
-- differs between engines, or a whole-text match makes them unnecessary.
--
-- The matcher follows every position a pattern can reach at once (a set of
-- positions per step), so it never backtracks and always terminates.
module LawSpec.Regex (Regex(..), parseRegex, regexMatches, regexMatchesText) where

import Data.Char (isDigit, ord)
import Data.List (nub, sort)

-- A class item matches a code point inside one of its ranges, or, when
-- negated, one outside all of them.
data Regex
  = Characters Bool [(Bool, [(Int, Int)])]
  | Sequence [Regex]
  | Alternatives [Regex]
  | Repeat Regex Int (Maybe Int)
  deriving (Eq, Show)

repeatLimit :: Int
repeatLimit = 1000

-- The pattern, or why it is not a portable regex.
parseRegex :: String -> Either String Regex
parseRegex source = do
  (r, rest) <- sequenceOf (zip [0 ..] (map ord source))
  case rest of
    [] -> Right r
    (_, c) : _ | c == ord ')' -> Left "a ) has no ( before it; write \\) for the character"
    (i, _) : _ -> Left ("unexpected character at position " ++ show i)
  where
    -- Positions are counted in code points from 0, for error messages.
    sequence' input acc = case input of
      [] -> pure (Sequence (reverse acc), [])
      (_, c) : _ | c == ord '|' || c == ord ')' -> pure (Sequence (reverse acc), input)
      _ -> do
        (atom', rest) <- atom input
        (repeated, rest') <- quantified atom' rest
        sequence' rest' (repeated : acc)
    atom input = case input of
      (i, c) : rest
        | c == ord '(' -> do
            let inner = case rest of
                  (_, q) : (_, colon) : more | q == ord '?' && colon == ord ':' -> Right more
                  (_, q) : _ | q == ord '?' -> Left ("position " ++ show i ++ ": only (?: ...) groups are portable; named groups, lookaround and flags are not")
                  _ -> Right rest
            body <- inner
            (r, after) <- sequenceOf body
            case after of
              (_, close) : more | close == ord ')' -> pure (r, more)
              _ -> Left ("the ( at position " ++ show i ++ " is never closed")
        | c == ord '[' -> characterClass i rest
        | c == ord '.' -> pure (Characters True [(False, [(10, 10)])], rest)
        | c == ord '\\' -> do
            (item, rest') <- escape i rest False
            pure (Characters False [item], rest')
        | c `elem` map ord "*+?" -> Left ("position " ++ show i ++ ": " ++ [toEnum c] ++ " has nothing before it to repeat")
        | c == ord '{' -> Left ("position " ++ show i ++ ": { starts a repetition and has nothing before it; write \\{ for the character")
        | c `elem` map ord "^$" -> Left ("position " ++ show i ++ ": a regex matches the whole text, so ^ and $ are not needed; write \\" ++ [toEnum c] ++ " for the character")
        | c == ord ']' || c == ord '}' -> Left ("position " ++ show i ++ ": write \\" ++ [toEnum c] ++ " for the character")
        | otherwise -> pure (Characters False [(False, [(c, c)])], rest)
      [] -> Left "unexpected end of the regex"
    sequenceOf input = do
      let collect inp = do
            (first, rest) <- sequence' inp []
            case rest of
              (_, c) : more | c == ord '|' -> do
                (others, rest') <- collect more
                pure (first : others, rest')
              _ -> pure ([first], rest)
      (branches, rest) <- collect input
      pure (case branches of [one] -> one; _ -> Alternatives branches, rest)
    quantified r input = case input of
      (i, c) : rest
        | c == ord '*' -> once (Repeat r 0 Nothing) rest
        | c == ord '+' -> once (Repeat r 1 Nothing) rest
        | c == ord '?' -> once (Repeat r 0 (Just 1)) rest
        | c == ord '{' -> do
            (low, high, rest') <- counts i rest
            once (Repeat r low high) rest'
      _ -> pure (r, input)
    once r rest = case rest of
      (i, c) : _ | c == ord '?' -> Left ("position " ++ show i ++ ": lazy repetition is not portable, and a whole-text match does not need it")
                 | c `elem` map ord "*+{" -> Left ("position " ++ show i ++ ": a repetition cannot itself be repeated; group it first")
      _ -> pure (r, rest)
    counts i input = do
      let (lowDigits, afterLow) = span (isDigit . toEnum . snd) input
      low <- number lowDigits
      case afterLow of
        (_, c) : rest | c == ord '}' -> bounded low (Just low) rest
                      | c == ord ',' -> case span (isDigit . toEnum . snd) rest of
                          ([], (_, close) : more) | close == ord '}' -> bounded low Nothing more
                          (highDigits@(_ : _), (_, close) : more) | close == ord '}' -> do
                            high <- number highDigits
                            bounded low (Just high) more
                          _ -> malformed
        _ -> malformed
      where
        malformed = Left ("position " ++ show i ++ ": a repetition is {n}, {n,} or {n,m}; write \\{ for the character")
        number [] = malformed
        number ds = let n = read (map (toEnum . snd) ds) :: Integer in
          if n > fromIntegral repeatLimit then Left ("position " ++ show i ++ ": a repetition count is at most " ++ show repeatLimit) else Right (fromInteger n)
        bounded low high rest = case high of
          Just h | h < low -> Left ("position " ++ show i ++ ": in {n,m}, n must not exceed m")
          _ -> Right (low, high, rest)
    escape i input inClass = case input of
      (_, c) : rest -> case toEnum c of
        'd' -> pure ((False, digits), rest)
        'D' -> pure ((True, digits), rest)
        'w' -> pure ((False, word), rest)
        'W' -> pure ((True, word), rest)
        's' -> pure ((False, space), rest)
        'S' -> pure ((True, space), rest)
        'n' -> single 10 rest
        't' -> single 9 rest
        'r' -> single 13 rest
        'f' -> single 12 rest
        'v' -> single 11 rest
        ch | ch `elem` ("\\.^$|?*+()[]{}-/" :: String) -> single c rest
           | ch == 'b' && inClass -> Left ("position " ++ show i ++ ": [\\b] means different things in different engines")
           | otherwise -> Left ("position " ++ show i ++ ": \\" ++ [ch] ++ " is not a portable escape")
      [] -> Left "the regex ends with a lone \\"
      where single c rest = pure ((False, [(c, c)]), rest)
    characterClass i input = do
      let (negated, body) = case input of
            (_, c) : rest | c == ord '^' -> (True, rest)
            _ -> (False, input)
      (items, rest) <- classItems body True []
      pure (Characters negated items, rest)
      where
        classItems inp first acc = case inp of
          [] -> Left ("the [ at position " ++ show i ++ " is never closed")
          (_, c) : rest | c == ord ']' && not first -> pure (reverse acc, rest)
                        | c == ord ']' -> Left ("position " ++ show i ++ ": an empty class is not portable; write \\] for the character")
          _ -> do
            (item, rest) <- classAtom inp
            case (item, rest) of
              ((False, [(low, _)]), (_, dash) : (j, next) : more)
                | dash == ord '-' && next /= ord ']' -> do
                    ((negatedHigh, highRanges), more') <- classAtom ((j, next) : more)
                    case (negatedHigh, highRanges) of
                      (False, [(high, high')]) | high == high' -> do
                        if high < low then Left ("position " ++ show j ++ ": a range must run from low to high") else pure ()
                        classItems more' False ((False, [(low, high)]) : acc)
                      _ -> Left ("position " ++ show j ++ ": a range ends with one character")
              _ -> classItems rest False (item : acc)
        classAtom inp = case inp of
          (j, c) : rest
            | c == ord '\\' -> escape j rest True
            | c == ord '[' -> Left ("position " ++ show j ++ ": write \\[ for the character inside a class")
            | otherwise -> pure ((False, [(c, c)]), rest)
          [] -> Left ("the [ at position " ++ show i ++ " is never closed")
    digits = [(48, 57)]
    word = [(48, 57), (65, 90), (95, 95), (97, 122)]
    space = [(9, 13), (32, 32)]

-- Whether the pattern matches all of the code points.
regexMatches :: Regex -> [Int] -> Bool
regexMatches r text = n `elem` reach r [0]
  where
    n = length text
    indexed = zip [0 ..] text
    at p = lookup p indexed
    reach node positions = case node of
      Characters negated items -> nub [p + 1 | p <- positions, Just c <- [at p], member negated items c]
      Sequence rs -> foldl (flip reach) positions rs
      Alternatives rs -> normal (concatMap (`reach` positions) rs)
      Repeat body low high ->
        let required = iterate (reach body) positions !! low
            more seen frontier limit
              | null frontier || limit == Just 0 = seen
              | otherwise =
                  let next = [p | p <- reach body frontier, p `notElem` seen]
                  in more (normal (seen ++ next)) next (subtract 1 <$> limit)
        in more (normal required) required (subtract low <$> high)
    normal = sort . nub
    member negated items c = negated /= any (\(itemNegated, ranges) -> itemNegated /= any (\(lo, hi) -> lo <= c && c <= hi) ranges) items

-- The pattern's verdict on a text, or why the pattern is invalid.
regexMatchesText :: String -> [Int] -> Either String Bool
regexMatchesText pattern text = (`regexMatches` text) <$> parseRegex pattern
