-- | One-line Scala code read back into its brackets, so code built as text
-- (the typed conversions) is laid out as scalafmt lays it out: a call's
-- arguments and a type's arguments break one a line inside their brackets,
-- and a lambda's body after its arrow. Strings are kept whole.
module LawSpec.ScalaText (scalaText) where

import qualified LawSpec.Code.Doc as D

data Piece = Token String | Bracket Char [[Piece]] Char

-- | The code as a document.
scalaText :: String -> D.Doc
scalaText s = case pieces s of
  Just (ps, "") -> render ps
  _ -> D.text s

render :: [Piece] -> D.Doc
render ps@(Token t : _) | take 5 t == "case ", Just (pattern, body) <- lambdaSplit ps =
  -- A case's body is on lines of its own, so scalafmt aligns no arrows.
  mconcat (map piece pattern) <> D.text " =>" <> D.nest 2 (D.hardline <> render body)
render ps = case lambdaSplit ps of
  Just (params, body) -> D.group (mconcat (map piece params) <> D.text " =>" <> D.nest 2 (D.softline <> render body))
  Nothing -> mconcat (map piece ps)

-- params => body, at the top level of a bracket's item.
lambdaSplit :: [Piece] -> Maybe ([Piece], [Piece])
lambdaSplit ps = go [] ps
  where
    go before (Token t : rest) = case breakOn " => " t of
      Just (a, b) -> Just (reverse before ++ [Token a | not (null a)], [Token b | not (null b)] ++ rest)
      Nothing -> go (Token t : before) rest
    go before (p : rest) = go (p : before) rest
    go _ [] = Nothing

breakOn :: String -> String -> Maybe (String, String)
breakOn needle = go ""
  where
    go acc hay@(c : rest)
      | take (length needle) hay == needle = Just (reverse acc, drop (length needle) hay)
      | otherwise = go (c : acc) rest
    go _ [] = Nothing

piece :: Piece -> D.Doc
piece p = case p of
  Token t -> D.text t
  Bracket open [] close -> D.text [open, close]
  Bracket '(' [single] ')' | Just (params, body) <- lambdaSplit single ->
    D.group (D.text "(" <> mconcat (map piece params) <> D.text " =>" <> D.nest 2 (D.softline <> render body) <> D.softbreak <> D.text ")")
  Bracket open items close ->
    D.group (D.text [open] <> D.nest 2 (D.softbreak <> D.commaSep (map render items)) <> D.softbreak <> D.text [close])

-- Tokens and brackets up to an unmatched closing bracket or a top-level comma.
pieces :: String -> Maybe ([Piece], String)
pieces s = case s of
  [] -> Just ([], [])
  c : _ | c `elem` (")]," :: String) -> Just ([], s)
  c : rest | c `elem` ("([" :: String) -> do
    (items, after) <- itemsOf rest
    case after of
      close : more | close == closing c -> do
        (ps, remaining) <- pieces more
        Just (Bracket c items close : ps, remaining)
      _ -> Nothing
  '"' : rest -> do
    (literal, after) <- stringLiteral rest
    (ps, remaining) <- pieces after
    Just (glue (Token ('"' : literal)) ps, remaining)
  _ -> let (t, after) = break (`elem` ("()[],\"" :: String)) s
       in do
         (ps, remaining) <- pieces after
         Just (glue (Token t) ps, remaining)
  where
    closing '(' = ')'
    closing _ = ']'
    glue (Token a) (Token b : rest) = Token (a ++ b) : rest
    glue p rest = p : rest

-- A bracket's items, separated by ", ".
itemsOf :: String -> Maybe ([[Piece]], String)
itemsOf s = do
  (first, rest) <- pieces s
  case rest of
    ',' : ' ' : more -> do
      (others, after) <- itemsOf more
      Just (first : others, after)
    _ -> Just ([first | not (null first)], rest)

stringLiteral :: String -> Maybe (String, String)
stringLiteral s = case s of
  '\\' : c : rest -> do
    (t, r) <- stringLiteral rest
    pure ('\\' : c : t, r)
  '"' : rest -> Just ("\"", rest)
  c : rest -> do
    (t, r) <- stringLiteral rest
    pure (c : t, r)
  [] -> Nothing
