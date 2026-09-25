module LawSpec.Parser (parseSource) where

import LawSpec.Model
import LawSpec.Scalar
import Control.Monad.Combinators.Expr
import Control.Monad (void)
import Control.Monad.Reader (Reader, asks, runReader)
import qualified Data.Map.Strict as M
import Data.Char (isLower, isControl)
import Data.List (uncons)
import Data.Void (Void)
import Text.Megaparsec hiding (SourcePos, parse)
import Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer as L

type P = ParsecT Void String (Reader (M.Map String [Bool]))
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
  if x `elem` ["unit","law","requires","is","end","definition","description","rationale","example","expect","implies","and","true","false","references","are","Eq","where","refinement"] then fail "reserved identifier" else pure x
quoted :: P String
quoted = lexeme (char '`' *> some (satisfy (\c -> c /= '`' && not (isControl c))) <* char '`')
str :: P String
str = lexeme (char '"' *> manyTill L.charLiteral (char '"'))
parens :: P a -> P a
parens = between (symbol "(") (symbol ")")
typeP :: P Type
typeP = do
  a <- typeAtom
  option a (Arrow a <$> (symbol "->" *> typeP))
typeAtom :: P Type
typeAtom = try (parens $ do
    n <- ident; void (symbol "::"); t <- typeP
    p <- optional (keyword "where" *> expr)
    pure (Refined n t p))
  <|> parens typeP <|> do
    n <- ident
    headers <- asks (M.lookup n)
    case headers of
      Just kinds -> RefinementApp n <$> mapM argument kinds
      Nothing | n `elem` ["Nullable","Optional"] -> Applied n <$> typeAtom
              | otherwise -> pure (if maybe False (isLower . fst) (uncons n) then Variable n else Named n)
  where argument True = TypeArgument <$> typeAtom
        argument False = ValueArgument <$> (parens expr <|> try numeric <|> (BoolLit <$> boolP) <|> (StringLit <$> str) <|> (Var <$> ident))
param :: P (String,Type)
param = parens $ do
  n <- ident; void (symbol "::"); t <- typeP
  p <- optional (keyword "where" *> expr)
  pure (n,maybe t (\e -> Refined n t (Just e)) p)
constraintsP :: P [Constraint]
constraintsP = option [] (keyword "requires" *> some (do
  n <- choice [name <$ keyword name | name <- ["Eq","Integer","Ordered","Bounded"]]
  Capability n <$> typeP))
refinementP :: P Refinement
refinementP = do
  keyword "refinement"; n <- ident; ps <- many param; cs <- constraintsP
  t <- keyword "is" *> typeP <* keyword "end"
  pure (Refinement n ps cs t)
expr :: P Expr
expr = located $ makeExprParser application
  [ [Prefix (Unary "!" <$ try (lexeme (char '!' <* notFollowedBy (char '=')))), Prefix (Unary "-" <$ try (lexeme (char '-' <* notFollowedBy digitChar)))]
  , [InfixR (Compose <$ symbol ".")]
  , [InfixL (Binary "*" <$ symbol "*"), InfixL (Binary "/" <$ symbol "/")]
  , [InfixL (Binary "+" <$ symbol "+"), InfixL (Binary "-" <$ symbol "-")]
  , [InfixN (Binary op <$ try (symbol op)) | op <- ["<=",">=","==","!=","<",">"]]
  , [InfixL (Binary "&&" <$ symbol "&&")]
  , [InfixL (Binary "||" <$ symbol "||")]
  ]
  where
    application = foldl1 Apply <$> some atom
    atom = located $ (BoolLit <$> boolP) <|> (StringLit <$> str) <|> try scalarP
      <|> parens (do e <- expr; option e (Annotate e <$> (symbol "::" *> typeP)))
      <|> try numeric <|> try (do n <- ident; void (char '.'); b <- ("min" <$ keyword "min") <|> ("max" <$ keyword "max"); pure (TypeBound b (if maybe False (isLower . fst) (uncons n) then Variable n else Named n))) <|> (Var <$> valueName)
    valueName = try (do keyword "prelude"; void (symbol "."); n <- ident; pure ("prelude." ++ n)) <|> ident
    -- An adjacent sign remains part of a numeric argument: f -42. For subtraction use x - 42.
located :: P Expr -> P Expr
located parser = do
  (value,range) <- withSpan parser
  pure (Located range value)
withSpan :: P a -> P (a,Span)
withSpan parser = do
  start <- getSourcePos
  value <- parser
  end <- getSourcePos
  let position p = Location (sourceName p) (unPos (sourceLine p)) (unPos (sourceColumn p))
  pure (value,Span (position start) (position end))
numeric :: P Expr
numeric = lexeme $ do
  sign <- option "" ((:[]) <$> oneOf ['-','+'])
  ds <- some digitChar
  fraction <- optional (try (char '.' *> some digitChar))
  powerToken <- optional (try (oneOf ['e','E'] *> L.signed (pure ()) L.decimal))
  let power = maybe 0 id powerToken
  let coefficient = read ((if sign == "+" then "" else sign) ++ ds ++ maybe "" id fraction)
  pure $ case (fraction,powerToken) of
    (Nothing,Nothing) -> Number coefficient
    _ -> DecimalNumber coefficient (power - maybe 0 (fromIntegral . length) fraction)
scalarP :: P Expr
scalarP = ScalarLit <$> choice
  [ SAbsent "Unit" <$ keyword "unitValue", SAbsent "Null" <$ keyword "null", SAbsent "Undefined" <$ keyword "undefined"
  , constructor "rational" (SRational <$> integer <* symbol "," <*> integer)
  , constructor "decimal" (SDecimal <$> integer <* symbol "," <*> integer)
  , constructor "symbol" (SSymbol <$> str <* symbol "," <*> str)
  , choice [constructor n (SSequence t <$> units) | (n,t) <- [("bytes","Bytes"),("codePoints","CodePointText"),("utf16","Utf16Text")]]
  , choice [constructor n (SCharacter t <$> unitInteger) | (n,t) <- [("char","Char"),("codePoint","CodePoint"),("codeUnit16","CodeUnit16")]]
  , choice [constructor n (SFloat t <$> str) | (n,t) <- [("float32Bits","Float32"),("float64Bits","Float64")]]
  , choice [constructor n (do r <- component t; void (symbol ","); i <- component t; pure (SComplex result r i)) | (n,t,result) <- [("complex64","Float32","Complex64"),("complex128","Float64","Complex128")]]
  , choice [constructor n (SPresent t . Just <$> scalarLiteral) | (n,t) <- [("nullable","Nullable"),("optional","Optional")]]
  ]
  where
    constructor n p = try (keyword n *> parens p)
    integer = lexeme (L.signed (pure ()) L.decimal)
    unitInteger = do n <- integer; if n >= 0 && n <= 1114111 then pure (fromInteger n) else fail "code point or unit outside representable range"
    units = between (symbol "[") (symbol "]") (unitInteger `sepBy` symbol ",")
    scalarLiteral = do e <- scalarP <|> numeric <|> (StringLit <$> str) <|> (BoolLit <$> boolP)
                       case e of ScalarLit v -> pure v; Number n -> pure (SInteger "BigInt" n); DecimalNumber c p -> pure (SDecimal c p); StringLit s -> pure (textScalar s); BoolLit b -> pure (SBool b); _ -> fail "concrete scalar required"
    component t = do
      e <- try numeric <|> scalarP
      let value = case e of Number n -> SInteger "BigInt" n; DecimalNumber c p -> SDecimal c p; ScalarLit s -> s; _ -> SAbsent "invalid"
      either fail pure (convertScalar 64 t value)
defP :: P Definition
defP = (do void (symbol "`for all`"); ps <- some param; void (symbol "."); Forall ps <$> defP)
   <|> do a <- clause
          option a (And a <$> (keyword "and" *> defP))
  where
    clause = (Invoke <$> quoted <*> many (parens expr <|> (BoolLit <$> boolP) <|> (StringLit <$> str) <|> (Number <$> lexeme (L.signed (pure ()) L.decimal)) <|> (Var <$> ident)))
      <|> try (do
        a <- expr
        (keyword "implies" *> (Implies a <$> defP))
          <|> (symbol "=" *> (Equal a <$> expr))
          <|> pure (Holds a))
      <|> parens defP
boolP :: P Bool
boolP = (keyword "true" *> pure True) <|> (keyword "false" *> pure False)
literalP :: P Literal
literalP = try (do e <- scalarP; case e of ScalarLit v -> pure (ScalarLiteral v); _ -> fail "literal")
  <|> try (parens (do
        e <- numeric <|> scalarP
        void (symbol "::")
        t <- typeP
        case (e,t) of
          (Number n,Named name) -> either fail (pure . ScalarLiteral) (convertScalar 64 name (SInteger "BigInt" n))
          (DecimalNumber c p,Named name) -> either fail (pure . ScalarLiteral) (convertScalar 64 name (SDecimal c p))
          (ScalarLit v,Named name) -> either fail (pure . ScalarLiteral) (convertScalar 64 name v)
          _ -> fail "expected concrete annotated literal"))
  <|> (BoolLiteral <$> boolP) <|> (TextLiteral <$> str)
  <|> (do e <- numeric; case e of Number n -> pure (IntLiteral n); DecimalNumber c p -> pure (DecimalLiteral c p); ScalarLit v -> pure (ScalarLiteral v); _ -> fail "literal")

block :: String -> P a -> P a
block n p = keyword n *> keyword "is" *> p <* keyword "end"
lawP :: P Law
lawP = do
  pos <- getSourcePos
  keyword "law"
  n <- quoted
  ps <- many param
  req <- constraintsP
  keyword "is"
  d <- block "definition" defP
  desc <- option "" (block "description" str)
  why <- option "" (block "rationale" str)
  ex <- many $ do
    keyword "example"; en <- quoted; keyword "is"
    bs <- some ((,) <$> ident <* symbol "=" <*> literalP)
    checks <- many (keyword "expect" *> (Expectation <$> expr <* symbol "=" <*> literalP))
    keyword "end"; pure (Example en bs checks)
  refs <- option [] (keyword "references" *> keyword "are" *> some str <* keyword "end")
  keyword "end"
  pure (Law n ps req d desc why ex refs (Location (sourceName pos) (unPos (sourceLine pos)) (unPos (sourceColumn pos))))
unitP :: P Unit
unitP = do
  spaceP; keyword "unit"
  n <- concatWithDot <$> (lexeme ((:) <$> letterChar <*> many (alphaNumChar <|> char '_')) `sepBy1` symbol ".")
  declarations <- many ((Left <$> try refinementP) <|> (Right . Left <$> try (withSpan ((,) <$> ident <* symbol "::" <*> typeP))) <|> (Right . Right <$> lawP))
  eof
  pure (Unit n [f | Right (Left (f,_)) <- declarations] [l | Right (Right l) <- declarations] [r | Left r <- declarations] [] [(name,range) | Right (Left ((name,_),range)) <- declarations])
  where concatWithDot = foldr1 (\a b -> a ++ "." ++ b)
parseSource :: Source -> Either [Diagnostic] Unit
parseSource (Source p s) = case runReader (runParserT unitP p s) (headers s) of
  Left e -> Left [Diagnostic "parse" (errorBundlePretty e) Nothing]
  Right u -> Right u

-- Read declaration arities before parsing applications, including forward references.
-- Strings, quoted law names and comments are consumed atomically.
headers :: String -> M.Map String [Bool]
headers source = M.fromList (scan tokens) where
  tokens = either (const []) id $ runReader (runParserT (spaceP *> many token <* eof) "headers" source) M.empty
  token = ("<string>" <$ str) <|> ("<quoted>" <$ quoted)
      <|> lexeme ((:) <$> letterChar <*> many (alphaNumChar <|> char '_'))
      <|> symbol "::" <|> ((:[]) <$> lexeme anySingle)
  scan ("unit":_:rest) = scan (dropUnit rest)
  scan ("refinement":n:rest) = let (ks,remaining) = parametersH rest in (n,ks):scan remaining
  scan (_:rest) = scan rest
  scan [] = []
  dropUnit (".":_:rest) = dropUnit rest
  dropUnit rest = rest
  parametersH ("(":rest) = let (inside,remaining) = group (1 :: Int) [] rest
                               (ks,remaining') = parametersH remaining
                           in ((case inside of [_ ,"::","Type"] -> True; _ -> False):ks,remaining')
  parametersH rest = ([],rest)
  group _ acc [] = (reverse acc,[])
  group depth acc (t:rest)
    | t == ")" && depth == 1 = (reverse acc,rest)
    | otherwise = group (depth + if t == "(" then 1 else if t == ")" then -1 else 0) (t:acc) rest
