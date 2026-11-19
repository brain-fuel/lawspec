-- | Prolog declarations and imports for authoring advice, read as the
-- Prolog grammar's clauses and terms. A clause declares the functor of its
-- head (the left operand of its principal operator, or the whole term) when
-- that is a compound term or a dictionary; every dictionary declares its tag,
-- with its sorted keys as fields, as a model; a use_module, ensure_loaded,
-- include or reexport term imports its first argument. Atoms and variables
-- are the identifiers. Limits: operators are the standard ISO and SWI-Prolog
-- table (an op/3 directive is not honoured), and terms are read only as far
-- as finding a clause's principal operator.
-- ref:DEC-authoring-advisories
module LawSpec.Authoring.Languages.Prolog (facts) where

import Data.Char (isAlphaNum, isDigit, isHexDigit, isLower, isSpace, isUpper)
import Data.List (sort)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import LawSpec.Authoring.Syntax
import Text.Megaparsec
import Text.Megaparsec.Char (char, string)

facts :: Text -> Facts
facts source = case prologLeaves source of
  Left problem -> unreadable problem
  Right leaves -> case brackets [("(", ")"), ("[", "]"), ("{", "}")] leaves of
    Left problem -> unreadable problem
    Right trees -> assemble source leaves (concatMap (clause source) (clauses source trees) ++ terms source trees)
  where
    unreadable problem = failed ("Native syntax could not be read: " <> T.pack problem)

prologLeaves :: Text -> Either String [Leaf]
prologLeaves = lexSource (spaces [lineComment "%", blockComment False "/*" "*/"]) step
  where
    step previous =
      choice
        [ (: []) <$> plain characterCode,
          (: []) <$> plain number,
          (: []) <$> atom previous,
          (: []) <$> leafAt Name Just (identifierWith (\c -> isUpper c || c == '_') identifierCharacter),
          (: []) <$> leafAt Name (Just . stripQuotes) (quotedWith '\''),
          (: []) <$> plain (quotedWith '"'),
          (: []) <$> plain (quotedWith '`'),
          (: []) <$> symbol (T.singleton <$> satisfy (`elem` ("()[]{},|!;" :: String))),
          (: []) <$> symbol (takeWhile1P Nothing symbolCharacter)
        ]
    -- A word operator is a keyword of the grammar; so is a directive's
    -- prefix operator.
    atom previous = do
      start <- getOffset
      text <- identifierWith isLower identifierCharacter
      end <- getOffset
      let directive = fmap leafText previous `elem` [Just ":-", Just "?-"] && text `elem` prefixOperators
          keyword = text `elem` wordOperators || directive
      pure (Leaf (if keyword then Word else Name) text (if keyword then Nothing else Just text) start end)
    characterCode = do
      _ <- try (string "0'")
      code <- try (string "''") <|> (T.cons '\\' . T.singleton <$> (char '\\' *> anySingle)) <|> (T.singleton <$> anySingle)
      pure ("0'" <> code)
    number = do
      digits <- takeWhile1P Nothing isDigit
      rest <-
        if digits == "0"
          then option "" (try (T.cons <$> satisfy (`elem` ("xob" :: String)) <*> takeWhile1P Nothing isHexDigit))
          else pure ""
      fraction <- option "" (try (T.cons <$> char '.' <*> takeWhile1P Nothing isDigit))
      exponent' <- option "" . try $ do
        e <- satisfy (`elem` ("eE" :: String))
        sign <- option "" (T.singleton <$> satisfy (`elem` ("+-" :: String)))
        power <- takeWhile1P Nothing isDigit
        pure (T.cons e sign <> power)
      pure (digits <> rest <> fraction <> exponent')

identifierCharacter :: Char -> Bool
identifierCharacter c = isAlphaNum c || c == '_'

symbolCharacter :: Char -> Bool
symbolCharacter c = c `elem` ("+-*/\\^<>=~:.?@#&$" :: String)

-- | A quoted literal with doubled-quote and backslash escapes.
quotedWith :: Char -> Lexer Text
quotedWith quote = do
  _ <- char quote
  body <- many (try (T.pack [quote, quote] <$ string (T.pack [quote, quote])) <|> (T.cons '\\' . T.singleton <$> (char '\\' *> anySingle)) <|> (T.singleton <$> satisfy (/= quote)))
  _ <- char quote
  pure (T.singleton quote <> T.concat body <> T.singleton quote)

wordOperators :: [Text]
wordOperators = ["is", "as", "mod", "in", "div", "rem", "xor", "rdiv"]

prefixOperators :: [Text]
prefixOperators = ["dynamic", "discontiguous", "initialization", "meta_predicate", "module_transparent", "multifile", "public", "table", "volatile"]

-- | The top-level clauses: trees up to each end token (a full stop
-- followed by layout, a comment or the end).
clauses :: Text -> [Tree] -> [[Tree]]
clauses source = filter (not . null) . go []
  where
    go acc [] = [reverse acc]
    go acc (tree : rest)
      | isEnd tree = reverse (tree : acc) : go [] rest
      | otherwise = go (tree : acc) rest
    isEnd tree = isAtom "." tree && endsClause (treeEnd tree)
    endsClause offset = case T.uncons (T.drop offset source) of
      Nothing -> True
      Just (c, _) -> isSpace c || c == '%'

-- | A clause's declaration: the functor or tag of its head.
clause :: Text -> [Tree] -> [Node]
clause source trees@(first : _) =
  [ declaration (treeStart first) (treeEnd (last trees)) "clause" functor False
  | Just functor <- [headName source (leftOperand term)]
  ]
  where
    term = filter (not . isClauseEnd) trees
    isClauseEnd tree = isAtom "." tree && treeEnd tree == treeEnd (last trees)
clause _ [] = []

-- | The functor of a compound term, or the tag of a dictionary.
headName :: Text -> [Tree] -> Maybe Text
headName _ [Atom functor, Group open _ _]
  | leafEnd functor == leafStart open,
    leafText open `elem` ["(", "{"],
    leafKind functor /= Symbol || leafText open == "(" =
      Just (leafText functor)
headName _ _ = Nothing

-- | The left operand of a term's principal infix operator, or the term.
leftOperand :: [Tree] -> [Tree]
leftOperand trees = case infixes of
  [] -> trees
  _ ->
    let top = maximum [priority | (_, priority, _) <- infixes]
        chosen = [(i, kind) | (i, priority, kind) <- infixes, priority == top]
        index = case chosen of
          (_, Yfx) : _ -> fst (last chosen)
          (i, _) : _ -> i
          [] -> 0
     in take index trees
  where
    infixes =
      [ (i, priority, kind)
      | (i, (previous, tree)) <- zip [1 ..] (zip trees (drop 1 trees)),
        operand previous,
        Just (priority, kind) <- [operatorAt tree],
        i + 1 < length trees
      ]
    operand (Atom leaf) = leafKind leaf `elem` [Name, Literal] || leafText leaf == "!"
    operand _ = True
    operatorAt (Atom leaf) = case [(p, k) | (text, p, k) <- operators, text == leafText leaf] of
      found : _ -> Just found
      [] -> Nothing
    operatorAt _ = Nothing

data Associativity = Xfx | Xfy | Yfx
  deriving (Eq)

operators :: [(Text, Int, Associativity)]
operators =
  [(o, 1200, Xfx) | o <- [":-", "-->"]]
    ++ [(o, 1100, Xfy) | o <- [";", "|"]]
    ++ [(o, 1050, Xfy) | o <- ["->", "*->"]]
    ++ [(",", 1000, Xfy), (":=", 990, Xfx)]
    ++ [(o, 700, Xfx) | o <- ["=", "\\=", "==", "\\==", "@<", "@>", "@=<", "@>=", "=..", "is", "=:=", "=\\=", "<", ">", "=<", ">=", ">:<", ":<", "as"]]
    ++ [(":", 600, Xfy)]
    ++ [(o, 500, Yfx) | o <- ["+", "-", "/\\", "\\/", "xor"]]
    ++ [(o, 400, Yfx) | o <- ["*", "/", "//", "rdiv", "<<", ">>", "mod", "rem", "div", "divmod"]]
    ++ [("**", 200, Xfx), ("^", 200, Xfy)]

-- | Dictionaries and imports anywhere in the source.
terms :: Text -> [Tree] -> [Node]
terms source = go
  where
    go (Atom functor : rest@(Group open inner close : _))
      | leafEnd functor == leafStart open = term functor open inner close ++ go rest
    go (tree : rest) = inside tree ++ go rest
    go [] = []
    inside (Group _ inner _) = go inner
    inside _ = []
    term functor open inner close
      | leafText open == "(",
        leafText functor `elem` ["use_module", "ensure_loaded", "include", "reexport"] =
          [ Node (leafStart functor) (leafEnd close) 0 (ImportFact (stripQuotes (spanText argument)))
          | argument@(_ : _) <- take 1 (statements (isAtom ",") inner)
          ]
      | leafText open == "{",
        leafKind functor == Name =
          [ Node
              (leafStart functor)
              (leafEnd close)
              0
              (DeclarationFact "dict" (leafText functor) True (sort (mapMaybe key (statements (isAtom ",") inner))))
          ]
      | otherwise = []
    key (Atom leaf : Atom colon : _) | leafText colon == ":", leafKind leaf == Name = Just (leafText leaf)
    key _ = Nothing
    spanText trees@(first : _) = slice source (treeStart first) (treeEnd (last trees))
    spanText [] = ""

-- | Without one leading and one trailing single quote.
stripQuotes :: Text -> Text
stripQuotes text =
  let inner = if T.isPrefixOf "'" text then T.drop 1 text else text
   in if T.isSuffixOf "'" inner then T.dropEnd 1 inner else inner
