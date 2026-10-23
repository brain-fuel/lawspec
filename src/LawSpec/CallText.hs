-- | A nested call's one-line text read back into its calls, so a layout can
-- break the arguments of a call built elsewhere as one token (a chain's
-- receiver). Only names, calls, generic arguments, string literals and
-- plain tokens are read; anything else is left whole.
module LawSpec.CallText (CallTree(..), parseCall) where

-- | A call (name and arguments) or a token kept whole.
data CallTree = Atom String | Apply String [CallTree] deriving (Eq, Show)

-- | The text as calls, when it is one.
parseCall :: String -> Maybe CallTree
parseCall text = case expression text of
  Just (tree, "") -> Just tree
  _ -> Nothing

-- An expression: a token, then optionally an argument list.
expression :: String -> Maybe (CallTree, String)
expression s = do
  (name, rest) <- token s
  case rest of
    '(' : more -> do
      (args, after) <- arguments more
      pure (Apply name args, after)
    _ -> pure (Atom name, rest)

-- A name with its generic arguments ([..] or <..>), or a string literal, up to
-- an argument list, a comma or a closing parenthesis.
token :: String -> Maybe (String, String)
token s = case s of
  '"' : rest -> do
    (literal, after) <- stringLiteral rest
    pure ('"' : literal, after)
  _ -> let (t, rest) = go (0 :: Int) s in if null t then Nothing else Just (t, rest)
  where
    go depth str = case str of
      c : rest | c `elem` ("[<" :: String) -> let (t, r) = go (depth + 1) rest in (c : t, r)
               | c `elem` ("]>" :: String) && depth > 0 -> let (t, r) = go (depth - 1) rest in (c : t, r)
               | depth == 0 && c `elem` ("(),\"" :: String) -> ([], str)
               | otherwise -> let (t, r) = go depth rest in (c : t, r)
      [] -> ([], [])

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

-- Arguments up to the closing parenthesis, separated by ", ".
arguments :: String -> Maybe ([CallTree], String)
arguments s = case s of
  ')' : rest -> Just ([], rest)
  _ -> do
    (first, rest) <- expression s
    case rest of
      ')' : after -> Just ([first], after)
      ',' : ' ' : more -> do
        (others, after) <- arguments' more
        Just (first : others, after)
      _ -> Nothing
  where
    arguments' str = do
      (first, rest) <- expression str
      case rest of
        ')' : after -> Just ([first], after)
        ',' : ' ' : more -> do
          (others, after) <- arguments' more
          Just (first : others, after)
        _ -> Nothing
