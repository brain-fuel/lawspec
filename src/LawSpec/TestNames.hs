-- Generated test names, from law labels. A law's tests are named after its
-- label, as a valid identifier on each target, unique in its unit and
-- stable while the label is: `charge captures once [native]` is
-- test_charge_captures_once_native in Python, TestChargeCapturesOnceNative
-- in Go, law_charge_captures_once_native in Rust and
-- lawChargeCapturesOnceNative on the JVM and in Haskell. A law's
-- several tests add a kind after a separator no name contains (Python's
-- __property, Go's _Property, the JVM's _property), so selecting one law's
-- tests never selects another's. JavaScript and TypeScript name tests by
-- the label itself.
module LawSpec.TestNames (lawWords, unitTestNames, testIdentifier, kindSuffix) where

import Data.Char (isAlphaNum, isAscii, isDigit, toLower, toUpper)
import Data.List (intercalate)

-- A label's words: ASCII letters and digits, lowercased.
lawWords :: String -> [String]
lawWords label =
  let ws = words (map (\c -> if isAscii c && isAlphaNum c then toLower c else ' ') label)
      capped = takeWords 0 ws
  in case capped of
      [] -> ["law"]
      w@(c : _) : rest | isDigit c -> "law" : w : rest
      _ -> capped
  where
    -- At most about 48 characters, whole words, so names fit a line.
    takeWords _ [] = []
    takeWords n (w : rest)
      | n > 0 && n + length w > 48 = []
      | otherwise = w : takeWords (n + length w + 1) rest

-- Each law's base identifier on a target, for a unit's laws in order, made
-- unique with a number.
unitTestNames :: String -> [String] -> [String]
unitTestNames target labels = go [] (map (bounded . lawWords) labels)
  where
    -- A single long label word must still fit a BEAM atom. Truncate before
    -- adding collision suffixes so each duplicate can obtain a fresh name.
    bounded = if target `elem` ["erlang","elixir","gleam"] then map (take 48) else id
    go _ [] = []
    go seen (ws : rest) =
      let candidates = map (testIdentifier target) (ws : [ws ++ [show n] | n <- [2 :: Int ..]])
          chosen = head [c | c <- candidates, c `notElem` seen]
      in chosen : go (chosen : seen) rest

-- The base identifier of a law's tests on a target.
testIdentifier :: String -> [String] -> String
testIdentifier target ws = case target of
  "python" -> "test_" ++ intercalate "_" ws
  "rust" -> "law_" ++ intercalate "_" ws
  "erlang" -> "law_" ++ intercalate "_" ws
  "elixir" -> "law_" ++ intercalate "_" ws
  "gleam" -> "law_" ++ intercalate "_" ws
  "go" -> "Test" ++ concatMap capital ws
  _ -> "law" ++ concatMap capital ws
  where capital (c : cs) = toUpper c : cs
        capital [] = []

-- What a target adds to the base identifier for one of a law's tests:
-- example0, boundary0, property, skipped, knownFailing.
kindSuffix :: String -> String -> String
kindSuffix target kind = case target of
  "python" -> "__" ++ snake kind
  "go" -> "_" ++ capital kind
  "rust" -> ""
  _ -> "_" ++ kind
  where capital (c : cs) = toUpper c : cs
        capital [] = []
        snake = concatMap (\c -> if c `elem` ['A' .. 'Z'] then ['_', toLower c] else [c])
