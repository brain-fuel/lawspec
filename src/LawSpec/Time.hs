-- Durations: a built-in unit, lawspec.time, added only to programs that use
-- it, as lawspec.collections is. A Duration is a whole number of microseconds
-- from 0 to durationLimit, about 146 years: the largest range every target's
-- native duration holds exactly. Its operations are checked LawSpec
-- definitions; arithmetic that would leave the range fails, as division by
-- zero does.
--
-- Literals such as 250ms are prelude calls (prelude.milliseconds 250), and
-- +, -, *, the comparisons and prelude.quot on durations elaborate to the
-- unit's definitions.
module LawSpec.Time
  ( timeUnit, timeAlias, timeSource, usesTime, timeOperation, timeOperations
  , durationType, durationLimit, durationSuffixes, durationFactor, durationArithmetic, durationValue, durationDefinitions
  ) where

import Data.Char (isAlphaNum, isDigit)
import Data.List (isPrefixOf, tails)

timeUnit :: String
timeUnit = "lawspec.time"

-- The implicit import's alias; prelude.<op> resolves through it.
timeAlias :: String
timeAlias = "lawspecTime"

durationType :: String
durationType = timeUnit ++ "::type::Duration"

-- 2^62 - 1 nanoseconds, in whole microseconds.
durationLimit :: Integer
durationLimit = 4611686018427387

-- Literal suffixes, longest first, and the prelude constructor each names.
durationSuffixes :: [(String, String)]
durationSuffixes = [("min", "minutes"), ("ms", "milliseconds"), ("us", "microseconds"), ("s", "seconds"), ("h", "hours"), ("d", "days")]

-- Microseconds per unit, by constructor.
durationFactor :: String -> Integer
durationFactor name = maybe 1 id (lookup name factors)

factors :: [(String, Integer)]
factors = [("microseconds", 1), ("milliseconds", 1000), ("seconds", 1000000), ("minutes", 60000000), ("hours", 3600000000), ("days", 86400000000)]

-- prelude.<op> and the definition implementing it.
timeOperations :: [(String, String)]
timeOperations =
  [ (unit, unit) | unit <- ["microseconds", "milliseconds", "seconds", "minutes", "hours", "days"] ] ++
  [ ("toMicroseconds", "valueOfDuration") ]

timeOperation :: String -> Maybe String
timeOperation op = lookup op timeOperations

-- The definition an arithmetic operator on durations elaborates to.
durationArithmetic :: String -> Maybe String
durationArithmetic op = lookup op [("+", "durationPlus"), ("-", "durationMinus"), ("*", "durationTimes"), ("quot", "durationQuot")]

-- The definition unwrapping a duration, for comparisons.
durationValue :: String
durationValue = "valueOfDuration"

-- The definitions operators elaborate to; every unit using durations copies
-- them, and elaboration calls the copies.
durationDefinitions :: [String]
durationDefinitions = durationValue : "microseconds" : [name | op <- ["+", "-", "*", "quot"], Just name <- [durationArithmetic op]]

-- Whether a source uses durations: the type, a prelude constructor, or a
-- literal such as 250ms. A source that declares its own Duration keeps it.
usesTime :: String -> Bool
usesTime text =
  let code = stripComments text
      tokens = words (map (\c -> if isAlphaNum c || c `elem` ("._" :: String) then c else ' ') code)
      declared = or [keyword `elem` ["type", "wrapper"] && name == "Duration" | (keyword, name) <- zip tokens (drop 1 tokens)]
  in not declared && ("Duration" `elem` tokens || any (`elem` tokens) ["prelude." ++ op | (op, _) <- timeOperations] || any literal tokens)
  where
    literal token = case span isDigit token of
      ("", _) -> False
      (_, suffix) -> suffix `elem` map fst durationSuffixes
    stripComments = unlines . map takeComment . lines
    takeComment line = case [i | (i, rest) <- zip [0 :: Int ..] (tails line), "--" `isPrefixOf` rest] of
      i : _ -> take i line
      [] -> line

-- Each operation states its result exactly, so the totality audit can
-- follow durations through checked definitions.
timeSource :: String
timeSource = unlines
  [ "unit " ++ timeUnit
  , ""
  , "wrapper Duration is Integer where value >= 0 && value <= " ++ limit ++ " end"
  , ""
  , unlines [constructor name factor | (name, factor) <- factors]
  , "definition durationPlus (a :: Duration) (b :: Duration where valueOfDuration a + valueOfDuration b <= " ++ limit ++ ")"
  , "    :: (r :: Duration where valueOfDuration r == valueOfDuration a + valueOfDuration b) is"
  , "  Duration (valueOfDuration a + valueOfDuration b)"
  , "end"
  , ""
  , "definition durationMinus (a :: Duration) (b :: Duration where valueOfDuration b <= valueOfDuration a)"
  , "    :: (r :: Duration where valueOfDuration r == valueOfDuration a - valueOfDuration b) is"
  , "  Duration (valueOfDuration a - valueOfDuration b)"
  , "end"
  , ""
  -- A product's sign is not linear, so a non-negative product is stated.
  , "definition durationTimes (a :: Duration) (k :: Integer where valueOfDuration a * k >= 0 && valueOfDuration a * k <= " ++ limit ++ ")"
  , "    :: (r :: Duration where valueOfDuration r == valueOfDuration a * k) is"
  , "  Duration (valueOfDuration a * k)"
  , "end"
  , ""
  , "definition durationQuot (a :: Duration) (k :: Integer where k > 0)"
  , "    :: (r :: Duration where valueOfDuration r == prelude.quot (valueOfDuration a) k) is"
  , "  Duration (prelude.quot (valueOfDuration a) k)"
  , "end"
  ]
  where
    limit = show durationLimit
    constructor name factor = unlines
      [ "definition " ++ name ++ " (n :: Integer where n >= 0 && n <= " ++ show (durationLimit `div` factor) ++ ")"
      , "    :: (r :: Duration where valueOfDuration r == " ++ scaled ++ ") is"
      , "  Duration (" ++ scaled ++ ")"
      , "end" ]
      where scaled = if factor == 1 then "n" else "n * " ++ show (factor :: Integer)
