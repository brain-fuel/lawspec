module LawSpec.Parser (parseSource) where

import LawSpec.Model
import Control.Monad (void)
import Data.Char (isLower, isControl)
import Data.List (uncons)
import Data.Void (Void)
import Text.Megaparsec hiding (SourcePos, parse)
import Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer as L

type P = Parsec Void String
spaceP :: P ()
spaceP = L.space space1 (L.skipLineComment "--") empty
lexeme :: P a -> P a
lexeme = L.lexeme spaceP
symbol :: String -> P String
symbol = L.symbol spaceP
keyword :: String -> P ()
keyword s = lexeme (try (string s *> notFollowedBy (alphaNumChar <|> char '_')))
ident :: P String
ident = lexeme $ try $ do
  x <- (:) <$> letterChar <*> many (alphaNumChar <|> char '_')
  if x `elem` ["unit","law","requires","is","end","definition","description","rationale","example","references","are","Eq"] then fail "reserved identifier" else pure x
quoted :: P String
quoted = lexeme (char '`' *> some (satisfy (\c -> c /= '`' && not (isControl c))) <* char '`')
str :: P String
str = lexeme (char '"' *> manyTill L.charLiteral (char '"'))
parens :: P a -> P a
parens = between (symbol "(") (symbol ")")
typeP :: P Type
typeP = do
  a <- parens typeP <|> (do n <- ident; pure (if maybe False (isLower . fst) (uncons n) then Variable n else Named n))
  option a (Arrow a <$> (symbol "->" *> typeP))
param :: P (String,Type)
param = parens ((,) <$> ident <* symbol "::" <*> typeP)
expr :: P Expr
expr = do
  a <- foldl1 Apply <$> some atom
  option a (Compose a <$> (symbol "." *> expr))
  where atom = (StringLit <$> str) <|> parens expr <|> (Var <$> ident) <|> (Number <$> lexeme (L.signed (pure ()) L.decimal))
defP :: P Definition
defP = (do void (symbol "`for all`"); ps <- some param; void (symbol "."); Forall ps <$> defP)
   <|> (Invoke <$> quoted <*> many (parens expr <|> (Var <$> ident)))
   <|> (Equal <$> expr <* symbol "=" <*> expr)
block :: String -> P a -> P a
block n p = keyword n *> keyword "is" *> p <* keyword "end"
lawP :: P Law
lawP = do
  pos <- getSourcePos
  keyword "law"
  n <- quoted
  ps <- many param
  req <- option [] (keyword "requires" *> some (keyword "Eq" *> typeP))
  keyword "is"
  d <- block "definition" defP
  desc <- option "" (block "description" str)
  why <- option "" (block "rationale" str)
  ex <- many $ do
    keyword "example"; en <- quoted; keyword "is"
    bs <- some ((,) <$> ident <* symbol "=" <*> ((TextLiteral <$> str) <|> (IntLiteral <$> lexeme (L.signed (pure ()) L.decimal))))
    keyword "end"; pure (Example en bs)
  refs <- option [] (keyword "references" *> keyword "are" *> some str <* keyword "end")
  keyword "end"
  pure (Law n ps req d desc why ex refs (Location (sourceName pos) (unPos (sourceLine pos)) (unPos (sourceColumn pos))))
unitP :: P Unit
unitP = do
  spaceP; keyword "unit"
  n <- concatWithDot <$> (lexeme ((:) <$> letterChar <*> many (alphaNumChar <|> char '_')) `sepBy1` symbol ".")
  fs <- many (try ((,) <$> ident <* symbol "::" <*> typeP))
  ls <- many lawP
  eof
  pure (Unit n fs ls)
  where concatWithDot = foldr1 (\a b -> a ++ "." ++ b)
parseSource :: Source -> Either [Diagnostic] Unit
parseSource (Source p s) = case runParser unitP p s of
  Left e -> Left [Diagnostic "parse" (errorBundlePretty e) Nothing]
  Right u -> Right u
