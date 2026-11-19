-- | Erlang declarations, imports and module names for authoring advice:
-- each function clause (the grammar's fun_decl), -record and -type
-- declarations, -import's module and -module's name.
--
-- A source is split into forms at full stops (a dot followed by
-- whitespace, a comment or the end), and a function form into clauses at
-- semicolons outside case, if, receive, try, begin, maybe and fun ... end
-- blocks. Atoms are the identifiers, without their quotes; variables and
-- macro names are not. Limits: -include and -include_lib are not imports
-- (the grammar names them pp_include); macros are not expanded, so a
-- declaration a macro produces is not seen; a form the preprocessor
-- splits (-ifdef around half a function) is read as written.
-- ref:DEC-authoring-advisories
module LawSpec.Authoring.Languages.Erlang (facts) where

import Data.Char (isAlphaNum, isAsciiLower, isAsciiUpper, isSpace)
import Data.Text (Text)
import qualified Data.Text as T
import LawSpec.Authoring.Syntax
import Text.Megaparsec
import Text.Megaparsec.Char (char)

facts :: Text -> Facts
facts source = case erlangLeaves source of
  Left problem -> unreadable problem
  Right leaves -> case brackets [("(", ")"), ("[", "]"), ("{", "}")] leaves of
    Left problem -> unreadable problem
    Right trees -> assemble source leaves (concatMap (form source) (forms source trees))
  where
    unreadable problem = failed ("Native syntax could not be read: " <> T.pack problem)

erlangLeaves :: Text -> Either String [Leaf]
erlangLeaves = lexSource (spaces [lineComment "%"]) step
  where
    step previous =
      choice
        [ (: []) <$> plain stringLiteral,
          (: []) <$> quotedAtom,
          (: []) <$> plain character,
          (: []) <$> plain number,
          (: []) <$> word' previous,
          (: []) <$> symbol (operatorFrom operators <|> (T.singleton <$> anySingle))
        ]
    stringLiteral = do
      _ <- char '"'
      body <- many (T.cons '\\' . T.singleton <$> (char '\\' *> anySingle) <|> takeWhile1P Nothing (\c -> c /= '\\' && c /= '"'))
      _ <- char '"'
      pure ("\"" <> T.concat body <> "\"")
    quotedAtom = do
      start <- getOffset
      _ <- char '\''
      body <- many (T.cons '\\' . T.singleton <$> (char '\\' *> anySingle) <|> takeWhile1P Nothing (\c -> c /= '\\' && c /= '\''))
      _ <- char '\''
      end <- getOffset
      let inner = T.concat body
      pure (Leaf Name ("'" <> inner <> "'") (Just inner) start end)
    character = do
      _ <- char '$'
      escaped <- (T.cons '\\' . T.singleton <$> (char '\\' *> anySingle)) <|> (T.singleton <$> anySingle)
      pure ("$" <> escaped)
    number = do
      digits <- numberLike
      radix <- optional (try (T.cons <$> char '#' <*> takeWhile1P Nothing isAlphaNum))
      pure (digits <> maybe "" id radix)
    -- An atom is a name; a variable, a keyword or an attribute keyword
    -- (after "-" at the start of a form) is not.
    word' previous = do
      start <- getOffset
      text <- identifierWith (\c -> isAsciiLower c || isAsciiUpper c || c == '_') (\c -> isAlphaNum c || c == '_' || c == '@')
      end <- getOffset
      let isAtom' = maybe False (isAsciiLower . fst) (T.uncons text)
          attribute = fmap leafText previous == Just "-" && text `elem` attributes
          named = isAtom' && text `notElem` keywords && not attribute
      pure (Leaf (if named then Name else Word) text (if named then Just text else Nothing) start end)
    operators = ["->", "::", "||", "<-", "<=", "=>", ":=", "?=", "=:=", "=/=", "==", "/=", "=<", ">=", "++", "--", "<<", ">>", "..."]

keywords :: [Text]
keywords = ["after", "and", "andalso", "band", "begin", "bnot", "bor", "bsl", "bsr", "bxor", "case", "catch", "cond", "div", "else", "end", "fun", "if", "let", "maybe", "not", "of", "or", "orelse", "receive", "rem", "try", "when", "xor"]

-- | Attribute names the grammar spells as keywords.
attributes :: [Text]
attributes = ["module", "export", "export_type", "import", "record", "type", "opaque", "spec", "callback", "define", "include", "include_lib", "ifdef", "ifndef", "else", "endif", "undef", "elif", "if", "behaviour", "behavior", "compile", "feature", "optional_callbacks", "deprecated", "file"]

-- | Forms: top-level trees up to each full stop, which is kept.
forms :: Text -> [Tree] -> [[Tree]]
forms source = filter (not . null) . go []
  where
    go acc [] = [reverse acc]
    go acc (tree : rest)
      | stop tree = reverse (tree : acc) : go [] rest
      | otherwise = go (tree : acc) rest
    stop (Atom leaf) =
      leafText leaf == "."
        && maybe True (\(c, _) -> isSpace c || c == '%') (T.uncons (T.drop (leafEnd leaf) source))
    stop _ = False

form :: Text -> [Tree] -> [Node]
form source trees@(first : rest)
  | isAtom "-" first = attribute rest
  | otherwise = concatMap clause (clauses trees)
  where
    end = treeEnd (last trees)
    attribute (Atom keyword : arguments)
      | leafText keyword == "module",
        Group _ (name' : _) _ : _ <- arguments =
          [Node (treeStart first) end 0 (ModuleFact (treeText source name'))]
      | leafText keyword == "import",
        Group _ (module' : _) _ : _ <- arguments =
          [Node (treeStart first) end 0 (ImportFact (unquote (treeText source module')))]
      | leafText keyword == "record",
        Group _ (Atom name' : _) _ : _ <- arguments,
        leafKind name' == Name =
          [declaration (treeStart first) end "record_decl" (leafText name') True]
      | leafText keyword == "type" = case arguments of
          Group open inner _ : _ | leafText open == "(" -> typeAlias inner
          _ -> typeAlias arguments
    attribute _ = []
    typeAlias (Atom name' : more)
      | leafKind name' == Name =
          let nameEnd = case more of
                parameters@(Group open _ _) : _ | leafText open == "(" -> treeEnd parameters
                _ -> leafEnd name'
           in [declaration (treeStart first) end "type_alias" (slice source (leafStart name') nameEnd) True]
    typeAlias _ = []
    unquote text = maybe text id (T.stripPrefix "\"" text >>= T.stripSuffix "\"")
    clause clauseTrees@(Atom name' : _)
      | leafKind name' == Name =
          [declaration (leafStart name') (treeEnd (last clauseTrees)) "fun_decl" (leafText name') False]
    clause _ = []
form _ [] = []

-- | A function form's clauses, each with its separator.
clauses :: [Tree] -> [[Tree]]
clauses = filter (not . null) . go (0 :: Int) []
  where
    go _ acc [] = [reverse acc]
    go depth acc (tree : rest)
      | depth == 0, isAtom ";" tree = reverse (tree : acc) : go 0 [] rest
      -- A guard's semicolons separate its tests, not clauses.
      | depth == 0,
        isAtom "when" tree =
          let (guard, after) = break (isAtom "->") rest
           in go 0 (reverse guard ++ tree : acc) after
      | any (`isAtom` tree) ["case", "if", "receive", "try", "begin", "maybe"] = go (depth + 1) (tree : acc) rest
      | isAtom "fun" tree, opensBlock rest = go (depth + 1) (tree : acc) rest
      | isAtom "end" tree = go (max 0 (depth - 1)) (tree : acc) rest
      | otherwise = go depth (tree : acc) rest
    -- An anonymous fun (fun (...) -> ... end, or with a variable name);
    -- fun f/1 and fun m:f/1 have no end.
    opensBlock (next : more)
      | isGroup "(" next = True
      | Atom leaf <- next,
        maybe False (\(c, _) -> isAsciiUpper c || c == '_') (T.uncons (leafText leaf)),
        (group : _) <- more =
          isGroup "(" group
    opensBlock _ = False
