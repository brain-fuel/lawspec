-- | One-line Java code read back into its calls, so code built as text (the
-- typed definitions) wraps as Google Java Style wraps it: a call's
-- arguments break 4 deeper inside its parentheses. Strings, characters and
-- anything unbalanced are kept whole, and so are type arguments.
module LawSpec.JavaText (javaText, javaLayout) where

import qualified LawSpec.Code.Doc as D
import Data.List (isPrefixOf, isSuffixOf, isInfixOf)

data Piece = Token String | Parens [[Piece]]

-- | The code as a document.
javaText :: String -> D.Doc
javaText s = case pieces s of
  Just (ps, "") -> mconcat (map piece ps)
  _ -> D.text s

piece :: Piece -> D.Doc
piece p = case p of
  Token t -> D.text t
  Parens [] -> D.text "()"
  Parens items -> D.group (D.text "(" <> D.nest 4 (D.softbreak <> D.commaSep (map (mconcat . map piece) items)) <> D.text ")")

pieces :: String -> Maybe ([Piece], String)
pieces s = case s of
  [] -> Just ([], [])
  c : _ | c `elem` ("),{}" :: String) -> if c `elem` ("{}" :: String) then token else Just ([], s)
  '(' : rest -> do
    (items, after) <- itemsOf rest
    case after of
      ')' : more -> do
        (ps, remaining) <- pieces more
        Just (Parens items : ps, remaining)
      _ -> Nothing
  q : rest | q `elem` ("\"'" :: String) -> do
    (literal, after) <- quoted q rest
    (ps, remaining) <- pieces after
    Just (glue (Token (q : literal)) ps, remaining)
  _ -> token
  where
    token = let (t, after) = tokenOf s
            in if null t then Nothing else do
              (ps, remaining) <- pieces after
              Just (glue (Token t) ps, remaining)
    glue (Token a) (Token b : rest) = Token (a ++ b) : rest
    glue p rest = p : rest

-- | Text up to the next parenthesis, comma or quote, a comma between type
-- arguments (Pair<A, B>, a < right after a name) included.
tokenOf :: String -> (String, String)
tokenOf = go (0 :: Int) []
  where
    go depth acc s = case s of
      '<' : rest | named acc -> go (depth + 1) ('<' : acc) rest
      '>' : rest | depth > 0 -> go (depth - 1) ('>' : acc) rest
      ',' : rest | depth > 0 -> go depth (',' : acc) rest
      c : rest | c `notElem` ("(),\"'" :: String) -> go depth (c : acc) rest
      _ -> (reverse acc, s)
    named acc = case acc of
      c : _ -> isWord c
      [] -> False
    isWord c = c `elem` ('.' : '_' : '$' : ['a' .. 'z'] ++ ['A' .. 'Z'] ++ ['0' .. '9'])

itemsOf :: String -> Maybe ([[Piece]], String)
itemsOf s = do
  (first, rest) <- pieces s
  case rest of
    ',' : ' ' : more -> do
      (others, after) <- itemsOf more
      Just (first : others, after)
    _ -> Just ([first | not (null first)], rest)

quoted :: Char -> String -> Maybe (String, String)
quoted q s = case s of
  '\\' : c : rest -> do
    (t, r) <- quoted q rest
    pure ('\\' : c : t, r)
  c : rest | c == q -> Just ([q], rest)
  c : rest -> do
    (t, r) <- quoted q rest
    pure (c : t, r)
  [] -> Nothing

-- | Java written line by line, laid out in LawSpec's Java profile: a block's
-- brace on a line of its own (Allman; a lambda's and an array's stay), and
-- a line too long for 100 columns re-laid by its calls or, for a comment,
-- wrapped at words.
javaLayout :: String -> String
javaLayout = unlines . concatMap (fit . dropWhileEndSpace) . concatMap allman . lines
  where
    dropWhileEndSpace = reverse . dropWhile (== ' ') . reverse
    allman l =
      let (indent, body) = span (== ' ') l
          opens = " {" `isSuffixOf` body && not ("-> {" `isSuffixOf` body) && not ("[] {" `isSuffixOf` body)
            && not ("= {" `isSuffixOf` body) && not ("({" `isSuffixOf` body) && not ("//" `isPrefixOf` body) && not ("*" `isPrefixOf` body)
          header = take (length body - 2) body
      in case () of
        _ | opens, "} " `isPrefixOf` header -> [indent ++ "}", indent ++ drop 2 header, indent ++ "{"]
          | opens -> [indent ++ header, indent ++ "{"]
          | otherwise -> [l]
    fit l
      | length l <= 100 = [l]
      | otherwise =
          let (indent, body) = span (== ' ') l
              width = 100 - length indent
          in case () of
            _ | "/** " `isPrefixOf` body, " */" `isSuffixOf` body ->
                  [indent ++ "/**"] ++ map ((indent ++ " * ") ++) (wrap (width - 3) (words (drop 4 (take (length body - 3) body)))) ++ [indent ++ " */"]
              | "// " `isPrefixOf` body -> map ((indent ++ "// ") ++) (wrap (width - 3) (words (drop 3 body)))
              | "\"" `isInfixOf` body && not (balanced body) -> [l]
              | otherwise -> map (\x -> if null x then x else indent ++ x) (lines (D.render (D.Pretty width) (javaText body)))
    balanced body = case pieces body of
      Just (_, "") -> True
      _ -> False
    wrap width ws = go ws
      where
        go [] = []
        go (w : rest) = let (line', more) = fill w rest in line' : go more
        fill acc (w : rest) | length acc + 1 + length w <= width = fill (acc ++ " " ++ w) rest
        fill acc rest = (acc, rest)
