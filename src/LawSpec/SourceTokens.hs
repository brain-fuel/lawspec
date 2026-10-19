-- | Lossless tokens shared by dependency discovery and authoring tools.
module LawSpec.SourceTokens (Token(..), TokenKind(..), sourceTokens, restoreSource) where
import Data.Char (isAlphaNum, isSpace)
import Data.List (isPrefixOf)

data TokenKind = WordToken | SymbolToken | LiteralToken | PhraseToken | CommentToken | TriviaToken
  deriving (Eq,Show)
data Token = Token { tokenKind :: TokenKind, tokenText :: String, tokenOffset :: Int }
  deriving (Eq,Show)
sourceTokens :: String -> [Token]
sourceTokens = scan 0 Nothing
  where
    scan _ _ [] = []
    scan offset previous input = let (kind,value,rest) = next previous input
                                     previous' = if kind `elem` [TriviaToken,CommentToken] then previous else Just (kind,value)
      in Token kind value offset : scan (offset + length value) previous' rest
    next previous input
      | "--" `isPrefixOf` input = let (a,b) = break (== '\n') input in (CommentToken,a,b)
      | "\"|" `isPrefixOf` input = let (a,b) = delimited '|' (drop 2 input) in (PhraseToken,"\"|" ++ a,b)
      | "`|" `isPrefixOf` input = let (a,b) = delimited '|' (drop 2 input) in (PhraseToken,"`|" ++ a,b)
      | '"':rest <- input = let (a,b) = delimited '"' rest in (LiteralToken,'"':a,b)
      -- These existing constructs retain paired-backtick names in the
      -- canonical profile. Words inside a name (including if, all and end)
      -- do not open or close blocks. Canonical infix backticks stay unpaired.
      | '`':rest <- input, Just (value,remaining) <- headerName previous rest = (PhraseToken,value,remaining)
      | '`':rest <- input = let (a,b) = span (\c -> isAlphaNum c || c `elem` ("_." :: String)) rest in (PhraseToken,'`':a,b)
      | c:_ <- input, isSpace c = let (a,b) = span isSpace input in (TriviaToken,a,b)
      | c:_ <- input, isAlphaNum c || c == '_' = let (a,b) = span (\c -> isAlphaNum c || c == '_') input in (WordToken,a,b)
      | c:rest <- input = (SymbolToken,[c],rest)
      | otherwise = (TriviaToken,"",[])
    headerName previous rest = do
      following <- case previous of
        Just (WordToken,"scenario") -> Just "in"
        Just (WordToken,"benchmark") -> Just "is"
        _ -> Nothing
      let (name,closing) = break (== '`') rest
      remaining <- case closing of '`':more -> Just more; _ -> Nothing
      let nextWord = takeWhile (\c -> isAlphaNum c || c == '_') (skipTrivia remaining)
      if not (any (`elem` ['\n','\r']) name) && nextWord == following
        then Just ('`':name ++ "`",remaining) else Nothing
    skipTrivia input = case dropWhile isSpace input of
      '-':'-':rest -> skipTrivia (dropWhile (/= '\n') rest)
      rest -> rest
    delimited _ [] = ("",[])
    delimited end ('\\':c:rest) = let (a,b) = delimited end rest in ('\\':c:a,b)
    delimited end (c:rest) | c == end = ([c],rest)
                         | otherwise = let (a,b) = delimited end rest in (c:a,b)
restoreSource :: [Token] -> String
restoreSource = concatMap tokenText
