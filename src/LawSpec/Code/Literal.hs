-- | Native string literals. Each target has one deterministic escaping table:
-- printable characters are written as they are, the language's standard
-- escapes are used where it has them, and only what the language requires is
-- escaped otherwise. Printability comes from LawSpec's pinned Unicode tables,
-- never the host's, so native and WASM output agree.
-- ref:DEC-native-string-literals
module LawSpec.Code.Literal
  ( StringSyntax(..), QuoteChoice(..), stringSyntax, stringLiteral, literalFor, printable
  ) where

import Data.Char (ord)
import qualified Data.IntMap.Strict as IM
import Numeric (showHex)
import LawSpec.DisplayWidthData (unprintableRanges)

-- | Which quote delimits a literal. Formatters such as ruff and Prettier pick
-- the preferred quote unless the other needs fewer escapes.
data QuoteChoice = FixedQuote Char | FewerEscapes Char Char

data StringSyntax = StringSyntax
  { syntaxQuotes :: QuoteChoice
    -- The language's standard escapes (backslash, newline, tab, ...).
  , syntaxEscape :: Char -> Maybe String
    -- How an unprintable code point is written.
  , syntaxCodePoint :: Int -> String
    -- Printable characters the language still requires escaped, such as
    -- Kotlin's and Groovy's $ (string templates).
  , syntaxRequired :: Char -> Maybe String
  }

-- | Whether a character is written as it is: not a control, format,
-- surrogate, private-use, unassigned or separator character (the space is
-- printable).
printable :: Char -> Bool
printable c
  | n >= 0x20 && n < 0x7f = True
  | n < 0x20 || n == 0x7f = False
  | otherwise = case IM.lookupLE n unprintableTable of
      Just (_, hi) -> n > hi
      Nothing -> True
  where n = ord c

unprintableTable :: IM.IntMap Int
unprintableTable = IM.fromList unprintableRanges

-- | A literal in the given syntax, with its quotes.
stringLiteral :: StringSyntax -> String -> String
stringLiteral syntax value = [quote] ++ concatMap escape value ++ [quote]
  where
    quote = case syntaxQuotes syntax of
      FixedQuote q -> q
      FewerEscapes preferred other
        | length (filter (== preferred) value) > length (filter (== other) value) -> other
        | otherwise -> preferred
    escape c
      | c == quote = ['\\', c]
      | Just e <- syntaxEscape syntax c = e
      | not (printable c) = syntaxCodePoint syntax (ord c)
      | Just e <- syntaxRequired syntax c = e
      | otherwise = [c]

-- | A target's literal for a value.
literalFor :: String -> String -> String
literalFor target = stringLiteral (stringSyntax target)

hex :: Int -> Int -> String
hex digits n = let s = showHex n "" in replicate (digits - length s) '0' ++ s

-- \uXXXX, with a surrogate pair above the Basic Multilingual Plane, as
-- UTF-16 languages write it.
utf16Escape :: Int -> String
utf16Escape n
  | n < 0x10000 = "\\u" ++ hex 4 n
  | otherwise = let m = n - 0x10000
    in "\\u" ++ hex 4 (0xD800 + m `div` 0x400) ++ "\\u" ++ hex 4 (0xDC00 + m `mod` 0x400)

common :: [(Char, String)]
common = [('\\', "\\\\"), ('\n', "\\n"), ('\r', "\\r"), ('\t', "\\t")]

-- | Every target's table. Python and the web targets follow their
-- formatters' quote preference; the others have one string quote.
stringSyntax :: String -> StringSyntax
stringSyntax target = case target of
  -- ruff: double quotes unless single quotes need fewer escapes; \xhh,
  -- \uhhhh or \Uhhhhhhhh in lowercase hex.
  "python" -> StringSyntax (FewerEscapes '"' '\'') (`lookup` common)
    (\n -> if n < 0x100 then "\\x" ++ hex 2 n else if n < 0x10000 then "\\u" ++ hex 4 n else "\\U" ++ hex 8 n)
    (const Nothing)
  -- Prettier: double quotes unless single quotes need fewer escapes.
  "javascript" -> web
  "typescript" -> web
  -- gofmt leaves literals alone; Go's \u and \U.
  "go" -> StringSyntax (FixedQuote '"') (`lookup` common)
    (\n -> if n < 0x10000 then "\\u" ++ hex 4 n else "\\U" ++ hex 8 n) (const Nothing)
  "rust" -> StringSyntax (FixedQuote '"') (`lookup` (common ++ [('\0', "\\0")]))
    (\n -> "\\u{" ++ showHex n "" ++ "}") (const Nothing)
  "swift" -> StringSyntax (FixedQuote '"') (`lookup` (common ++ [('\0', "\\0")]))
    (\n -> "\\u{" ++ showHex n "" ++ "}") (const Nothing)
  "java" -> jvm (const Nothing)
  "scala" -> jvm (const Nothing)
  "clojure" -> jvm (const Nothing)
  "kotlin" -> jvm (\c -> if c == '$' then Just "\\$" else Nothing)
  "groovy" -> jvm (\c -> if c == '$' then Just "\\$" else Nothing)
  "csharp" -> StringSyntax (FixedQuote '"') (`lookup` (common ++ [('\0', "\\0")])) utf16Escape (const Nothing)
  "fsharp" -> StringSyntax (FixedQuote '"') (`lookup` common)
    (\n -> if n < 0x10000 then "\\u" ++ hex 4 n else "\\U" ++ hex 8 n) (const Nothing)
  -- Haskell's \& ends a numeric escape before a following digit; decimal
  -- escapes are what show writes, so they are used throughout.
  "haskell" -> StringSyntax (FixedQuote '"') (`lookup` common) (\n -> "\\" ++ show n ++ "\\&") (const Nothing)
  "erlang" -> StringSyntax (FixedQuote '"') (`lookup` common) (\n -> "\\x{" ++ showHex n "" ++ "}") (const Nothing)
  "elixir" -> StringSyntax (FixedQuote '"') (`lookup` common) (\n -> "\\u{" ++ showHex n "" ++ "}")
    (\c -> if c == '#' then Just "\\#" else Nothing)
  "gleam" -> StringSyntax (FixedQuote '"') (`lookup` common) (\n -> "\\u{" ++ showHex n "" ++ "}") (const Nothing)
  "hcl" -> StringSyntax (FixedQuote '"') (`lookup` common)
    (\n -> if n < 0x10000 then "\\u" ++ hex 4 n else "\\U" ++ hex 8 n)
    (\c -> if c `elem` ("$%" :: String) then Just [c, c] else Nothing)
  _ -> StringSyntax (FixedQuote '"') (`lookup` common) utf16Escape (const Nothing)
  where
    web = StringSyntax (FewerEscapes '"' '\'') (`lookup` (common ++ [('\x2028', "\\u2028"), ('\x2029', "\\u2029")]))
      utf16Escape (const Nothing)
    jvm = StringSyntax (FixedQuote '"') (`lookup` common) utf16Escape
