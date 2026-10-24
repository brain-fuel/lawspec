-- | One-line Java code read back into its calls, so code built as text (the
-- typed definitions) wraps as Google Java Style wraps it: a call's
-- arguments break 4 deeper inside its parentheses. Strings, characters and
-- anything unbalanced are kept whole, and so are type arguments.
module LawSpec.JavaText (javaText) where

import qualified LawSpec.Code.Doc as D

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
