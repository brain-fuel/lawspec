-- | Unicode 17.0.0 full default case folding, as ordinary checked definitions.
-- The C and F mappings are pinned; absent code points retain their spelling.
-- No target's locale, Unicode library, normalization or lowercasing is used.
-- ref:DEC-readable-notation
module LawSpec.CaseFold
  ( caseFoldUnit, caseFoldAlias, caseFoldOperation, usesCaseFold, caseFoldSource
  ) where

import LawSpec.CaseFoldData (caseFoldMappings)
import LawSpec.CaseFoldNames (caseFoldUnit,caseFoldAlias,caseFoldOperation)
import LawSpec.SourceTokens (sourceTokens,Token(..),TokenKind(..))
import Data.List (intercalate)

usesCaseFold :: String -> Bool
usesCaseFold text = any (`elem` ["caseFold","textContains"]) tokens ||
  any (== ["lawspec",".","text"]) [take 3 rest | rest <- suffixes tokens]
  where
    tokens = [tokenText token | token <- sourceTokens text,tokenKind token `notElem` [TriviaToken,CommentToken]]
    suffixes [] = []
    suffixes rest@(_:tail') = rest : suffixes tail'

-- Recursion halves a positive span using the existing integer-descent checker.
-- Both traversal and lookup have logarithmic stack depth, including Python.
-- Slicing and portable text ordering retain their existing checked semantics.
caseFoldSource :: String
caseFoldSource = unlines
  [ "unit lawspec.text"
  , "import lawspec.collections (Ordering)"
  , "function textContains (whole :: Text) (part :: Text) -> Bool is"
  , "  prelude.contains whole part"
  , "end function"
  , "function textCaseFold (text :: Text) -> Text is"
  , "  textFoldSpan text 0 (prelude.length text)"
  , "end function"
  , "function textFoldSpan (text :: Text) (start :: Integer) (count :: Integer) -> Text is"
  , "  if count <= 0 then \"\" else"
  , "  if count = 1 then textFoldPoint (prelude.slice start (start + 1) text) else"
  , "    let half = prelude.quot count 2 in"
  , "    textFoldSpan text start half ++ textFoldSpan text (start + half) half ++"
  , "      (if prelude.rem count 2 = 0 then \"\" else"
  , "        textFoldPoint (prelude.slice (start + 2 * half) (start + 2 * half + 1) text) end if) end let end if end if"
  , "end function"
  ] ++ intercalate "\n" (definitions "textFoldPoint" caseFoldMappings) ++ "\nend unit\n"
  where
    -- Keep each generated method small enough for JVM bytecode limits.
    definitions name pairs
      | length pairs <= 64 = [definition name (lookupTree pairs)]
      | otherwise = case splitAt (length pairs `div` 2) pairs of
          (before,(key,value):after) ->
            definition name (branch key value (name ++ "Left point") (name ++ "Right point")) :
            definitions (name ++ "Left") before ++ definitions (name ++ "Right") after
          _ -> []
    definition name body = "function " ++ name ++ " (point :: Text) -> Text is\n" ++ body ++ "\nend function"
    branch key value before after = "first matching case of prelude.compare point " ++ show key ++ ":\n" ++
      "when Less then " ++ before ++ "\nwhen Equal then " ++ show value ++ "\nwhen Greater then " ++ after ++ "\nend case"
    lookupTree [] = "point"
    lookupTree pairs = case splitAt (length pairs `div` 2) pairs of
      (before,(key,value):after) -> branch key value (lookupTree before) (lookupTree after)
      _ -> "point"
