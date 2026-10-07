-- | JavaScript string tokens; layout never rewrites their payloads.
module LawSpec.Code.JavaScript (stringLiteral, quoted, stringExpression) where

import Data.Char (ord)
import Numeric (showHex)
import qualified LawSpec.Code.Doc as D

-- | Single quotes, as Google's JavaScript style asks, with every special
-- character escaped. ref:google-style-guides
stringLiteral :: String -> String
stringLiteral value = "'" ++ concatMap escape value ++ "'"
  where
    escape '\'' = "\\'"
    escape '\\' = "\\\\"
    escape '\n' = "\\n"
    escape '\r' = "\\r"
    escape '\t' = "\\t"
    escape '\b' = "\\b"
    escape '\f' = "\\f"
    escape c
      | ord c < 32 || ord c `elem` [0x2028,0x2029] || ord c >= 0xd800 && ord c <= 0xdfff =
          let digits = showHex (ord c) "" in "\\u" ++ replicate (4 - length digits) '0' ++ digits
      | otherwise = [c]

-- | As stringLiteral, as a document that layout never breaks.
quoted :: String -> D.Doc
quoted = D.text . stringLiteral

-- | Value expressions may concatenate escaped chunks; property names must remain
-- single tokens and use quoted instead. Bound escaped width, not source length.
stringExpression :: String -> D.Doc
stringExpression value
  | length (stringLiteral value) <= 26 = quoted value
  | otherwise = D.group (D.text "(" <> D.nest 4
      (D.softbreak <> D.joinWith (D.text " +" <> D.softline)
        (map quoted (chunks value))) <> D.softbreak <> D.text ")")
  where
    chunks [] = []
    chunks rest =
      let count = max 1 (length (takeWhile
            (\n -> length (stringLiteral (take n rest)) <= 26) [1 .. length (take 24 rest)]))
      in take count rest : chunks (drop count rest)
