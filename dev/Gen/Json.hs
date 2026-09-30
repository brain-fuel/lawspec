{-# LANGUAGE NoOverloadedStrings #-}
-- JSON values rendered exactly as JSON.stringify(value, null, 2) renders them,
-- so generated JSON files and JavaScript data literals are deterministic.
module Gen.Json (Json(..), json, jsonString) where

import Data.Char (ord)
import Data.List (intercalate)
import Numeric (showHex)

data Json = String String | Number Integer | Bool Bool | Null | Array [Json] | Object [(String, Json)]

json :: Json -> String
json = go 0
  where
    go depth value = case value of
      String s -> jsonString s
      Number n -> show n
      Bool b -> if b then "true" else "false"
      Null -> "null"
      Array [] -> "[]"
      Object [] -> "{}"
      Array items -> container depth "[" "]" (map (go (depth + 1)) items)
      Object fields -> container depth "{" "}" [jsonString k ++ ": " ++ go (depth + 1) v | (k, v) <- fields]
    container depth open close items =
      open ++ "\n" ++ intercalate ",\n" (map (indent (depth + 1) ++) items) ++ "\n" ++ indent depth ++ close
    indent n = replicate (2 * n) ' '

-- JSON.stringify string escaping: quotes, backslashes, named and \u00XX
-- control escapes; everything else, including non-ASCII, is literal.
jsonString :: String -> String
jsonString s = "\"" ++ concatMap escape s ++ "\""
  where
    escape '"' = "\\\""
    escape '\\' = "\\\\"
    escape '\n' = "\\n"
    escape '\r' = "\\r"
    escape '\t' = "\\t"
    escape '\b' = "\\b"
    escape '\f' = "\\f"
    escape c | ord c < 0x20 = "\\u" ++ pad (showHex (ord c) "")
             | otherwise = [c]
    pad digits = replicate (4 - length digits) '0' ++ digits
