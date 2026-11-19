-- | JavaScript and TypeScript declarations and imports for authoring
-- advice: class and function declarations (not expressions, generators or
-- TypeScript signatures and abstract classes), every variable declarator
-- (destructuring patterns are named by their text), and TypeScript
-- interface, type alias and enum declarations, at any depth. An import
-- statement contributes its source; dynamic import(...) and import ... =
-- require(...) are unresolved imports, as the Tree-sitter extraction read
-- them. Statements end at semicolons and where automatic semicolon
-- insertion applies at a line end. Limits: no JSX; contextual keywords are
-- told from names by their neighbours, not by a full grammar.
-- ref:DEC-authoring-advisories
module LawSpec.Authoring.Languages.Script (facts) where

import Data.Char (isAlpha, isAlphaNum, isDigit, isSpace)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import LawSpec.Authoring.Syntax hiding (isAtom)
import Text.Megaparsec
import Text.Megaparsec.Char (char, string)

-- | The facts of a JavaScript source, or of a TypeScript one when the flag
-- is set.
facts :: Bool -> Text -> Facts
facts typescript source = case scriptLeaves typescript source of
  Left problem -> unreadable problem
  Right leaves -> case brackets [("(", ")"), ("[", "]"), ("{", "}")] leaves of
    Left problem -> unreadable problem
    Right trees -> assemble source leaves (scan (Context typescript source (position source)) True trees)
  where
    unreadable problem = failed ("Native syntax could not be read: " <> T.pack problem)

data Context = Context {typed :: Bool, text :: Text, table :: Position}

-- * Leaves

scriptSpace :: Lexer ()
scriptSpace = spaces [lineComment "//", blockComment False "/*" "*/"]

scriptLeaves :: Bool -> Text -> Either String [Leaf]
scriptLeaves typescript = lexSource scriptSpace (step typescript)

step :: Bool -> Maybe Leaf -> Lexer [Leaf]
step typescript previous =
  choice
    [ (: []) <$> hashbang,
      quotedString '\'',
      quotedString '"',
      template typescript,
      regex,
      (: []) <$> plain numberLike,
      (: []) <$> plain (try (T.cons <$> char '.' <*> takeWhile1P Nothing isDigit)),
      (: []) <$> scriptWord typescript previous,
      (: []) <$> symbol (operatorFrom operators <|> (T.singleton <$> anySingle))
    ]
  where
    hashbang = do
      offset <- getOffset
      if offset /= 0 then empty else plain ((<>) <$> string "#!" <*> takeWhileP Nothing (/= '\n'))
    regex
      | regexAllowed previous = do
          open <- symbol (string "/")
          notFollowedBy (char '/' <|> char '*')
          pattern' <- plain (T.concat <$> some regexPiece)
          close <- leafAt Literal (const Nothing) (string "/")
          flags <- optional (plain (takeWhile1P Nothing isAlpha))
          pure ([open, pattern', close] ++ maybe [] (: []) flags)
      | otherwise = empty
    regexPiece =
      (T.cons <$> char '\\' <*> (T.singleton <$> anySingle))
        <|> classPiece
        <|> takeWhile1P Nothing (\c -> c `notElem` ("\\[/\n" :: String))
    classPiece = do
      _ <- char '['
      body <- many ((T.cons <$> char '\\' <*> (T.singleton <$> anySingle)) <|> takeWhile1P Nothing (\c -> c `notElem` ("\\]\n" :: String)))
      _ <- char ']'
      pure ("[" <> T.concat body <> "]")
    operators = [">>>=", "...", "===", "!==", "**=", "<<=", "&&=", "||=", "??=", "=>", "==", "!=", "<=", ">=", "&&", "||", "??", "?.", "++", "--", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "**", "<<"]

-- | Whether a slash here starts a regular expression rather than division.
regexAllowed :: Maybe Leaf -> Bool
regexAllowed Nothing = True
regexAllowed (Just leaf) = case leafKind leaf of
  Name -> False
  Literal -> False
  Word -> leafText leaf `notElem` ["this", "super", "null", "true", "false", "undefined"]
  Symbol -> leafText leaf `notElem` [")", "]", "}", "++", "--", "'", "\"", "`"]

-- | A quoted string: its quotes and the pieces between them. The closing
-- quote is a literal leaf, so that it ends an expression.
quotedString :: Char -> Lexer [Leaf]
quotedString quote = do
  open <- symbol (T.singleton <$> char quote)
  body <- many (escape <|> ((: []) <$> plain (takeWhile1P Nothing (\c -> c /= quote && c /= '\\' && c /= '\n'))))
  close <- leafAt Literal (const Nothing) (T.singleton <$> char quote)
  pure ([open] ++ concat body ++ [close])

-- | A template literal, with the code of each substitution lexed in turn.
template :: Bool -> Lexer [Leaf]
template typescript = do
  open <- symbol (string "`")
  body <- many (escape <|> substitution <|> ((: []) <$> plain fragment))
  close <- leafAt Literal (const Nothing) (string "`")
  pure ([open] ++ concat body ++ [close])
  where
    fragment = T.concat <$> some (takeWhile1P Nothing (\c -> c `notElem` ("`\\$" :: String)) <|> try (T.singleton <$> char '$' <* notFollowedBy (char '{')))
    substitution = do
      open <- symbol (string "${")
      inner <- code (Just open) (0 :: Int) []
      pure (open : inner)
    code previous depth acc = do
      scriptSpace
      next <- lookAhead anySingle
      if next == '}' && depth == 0
        then do
          close <- leafAt Literal (const Nothing) (string "}")
          pure (reverse acc ++ [close])
        else do
          leaves <- step typescript previous
          let depth' = depth + length [() | l <- leaves, leafKind l == Symbol, leafText l == "{"] - length [() | l <- leaves, leafKind l == Symbol, leafText l == "}"]
          case leaves of
            [] -> fail "unrecognised character"
            _ -> code (Just (last leaves)) depth' (reverse leaves ++ acc)

-- | A word: a keyword, or a name (identifier, property, private name).
scriptWord :: Bool -> Maybe Leaf -> Lexer Leaf
scriptWord typescript previous = do
  start <- getOffset
  hash <- optional (char '#')
  first <- identifierWith (\c -> isAlpha c || c == '_' || c == '$') (\c -> isAlphaNum c || c == '_' || c == '$')
  end <- getOffset
  ahead <- lookAhead (takeWhileP Nothing isSpace *> (try (takeP Nothing 2) <|> takeRest))
  let spelled = maybe first (\_ -> "#" <> first) hash
      keyword = not (isJust hash) && isKeyword typescript (fmap leafText previous) spelled ahead
  pure (Leaf (if keyword then Word else Name) spelled (if keyword then Nothing else Just spelled) start end)

isKeyword :: Bool -> Maybe Text -> Text -> Text -> Bool
isKeyword typescript previous spelled ahead
  | previous `elem` [Just ".", Just "?."] = False
  | next == Just ':' && previous `elem` [Just "{", Just ","] = False
  | spelled `elem` reserved = True
  | spelled `elem` ["get", "set", "static"] = startsName || next `elem` map Just "[#*'\"{"
  | spelled == "async" = startsName || next `elem` map Just "*[#("
  | spelled == "of" = previous `notElem` [Nothing, Just "=", Just "(", Just ","] && not ends
  | spelled == "from" = next `elem` map Just "'\""
  | spelled == "as" = startsName || next `elem` map Just "{[("
  | spelled == "let" = not ends
  | typescript && spelled `elem` modifiers = startsName || next `elem` map Just "[#{"
  | typescript && spelled `elem` ["keyof", "infer", "unique", "asserts", "namespace"] = startsName
  | typescript && spelled == "is" = startsName
  | typescript && spelled `elem` ["satisfies", "implements"] = startsName || next == Just '{'
  | typescript && spelled == "type" = startsName || next == Just '{'
  | typescript && spelled == "module" = startsName || next `elem` map Just "'\""
  | typescript && spelled == "interface" = startsName
  | typescript && spelled `elem` predefined =
      not (next `elem` map Just ":(." || (next == Just '=' && second /= Just '>') || (next == Just '?' && second `elem` map Just ":."))
  | otherwise = False
  where
    next = fst <$> T.uncons ahead
    second = fst <$> T.uncons (T.drop 1 ahead)
    startsName = maybe False (\c -> isAlpha c || c == '_' || c == '$') next
    ends = maybe True (`elem` ("=.(,);:}]" :: String)) next

reserved :: [Text]
reserved =
  [ "break",
    "case",
    "catch",
    "class",
    "const",
    "continue",
    "debugger",
    "default",
    "delete",
    "do",
    "else",
    "export",
    "extends",
    "finally",
    "for",
    "function",
    "if",
    "import",
    "in",
    "instanceof",
    "new",
    "return",
    "super",
    "switch",
    "this",
    "throw",
    "try",
    "typeof",
    "var",
    "void",
    "while",
    "with",
    "yield",
    "await",
    "null",
    "true",
    "false",
    "undefined",
    "enum"
  ]

modifiers, predefined :: [Text]
modifiers = ["declare", "abstract", "readonly", "private", "public", "protected", "override", "accessor"]
predefined = ["number", "string", "boolean", "any", "unknown", "never", "object"]

-- * Declarations

-- | Scan a sequence of trees; the flag says whether it starts a statement.
scan :: Context -> Bool -> [Tree] -> [Node]
scan context opensStatement = go Nothing
  where
    go _ [] = []
    go previous trees@(tree : rest)
      -- Dynamic import(...): an import node without a source.
      | isWord "import" tree,
        next : _ <- rest,
        isGroup "(" next =
          limitAt tree : go (Just tree) rest
      | isWord "import" tree || isWord "new" tree,
        Atom dot : Atom property : more <- rest,
        leafText dot == ".",
        leafText property `elem` ["meta", "target"] =
          Node (leafStart property) (leafEnd property) 0 KeywordFact : go (Just (Atom property)) more
      | statement previous tree,
        Just (nodes, remaining) <- declarationAt context trees =
          nodes ++ go (lastOf trees remaining) remaining
      | isWord "for" tree = case rest of
          Group open inner close : more | leafText open == "(" -> forHead context inner ++ go (Just (Group open inner close)) more
          Atom aw : Group open inner close : more | leafText aw == "await", leafText open == "(" -> forHead context inner ++ go (Just (Group open inner close)) more
          _ -> go (Just tree) rest
      | otherwise = nested context tree ++ go (Just tree) rest
    statement previous tree = case previous of
      Nothing -> opensStatement
      Just prior
        | isAtom ";" prior || isGroup "{" prior -> True
        | any (`isWord` prior) ["export", "default", "declare", "else", "do"] -> True
        | asi context prior tree -> True
        | otherwise -> False
    lastOf trees remaining = case drop (length trees - length remaining - 1) trees of
      t : _ -> Just t
      [] -> Nothing
    limitAt tree =
      Node (treeStart tree) (treeEnd tree) 0 (LimitFact ("Unresolved import syntax at line " <> T.pack (show (lineAt (table context) (treeStart tree)))))

-- | A token of code with this spelling (not a piece of a literal, whose
-- text may read the same).
isAtom :: Text -> Tree -> Bool
isAtom spelled (Atom leaf) = leafKind leaf /= Literal && leafText leaf == spelled
isAtom _ _ = False

isWord :: Text -> Tree -> Bool
isWord spelled (Atom leaf) = leafKind leaf == Word && leafText leaf == spelled
isWord _ _ = False

-- | Declarations nested in a group.
nested :: Context -> Tree -> [Node]
nested context (Group open inner _) = scan context (leafText open == "{") inner
nested _ _ = []

-- | A for statement's head: declarators unless it iterates (of, in).
forHead :: Context -> [Tree] -> [Node]
forHead context (first : rest)
  | any (`isWord` first) ["let", "const", "var"],
    not (any (\t -> isWord "of" t || isWord "in" t) rest) =
      let (declarators, after) = break (isAtom ";") rest
       in variableDeclarators context declarators ++ scan context False after
forHead context inner = scan context False inner

-- | Whether a statement ends between two trees on different lines.
asi :: Context -> Tree -> Tree -> Bool
asi context prior next =
  lineAt (table context) (treeEnd prior) < lineAt (table context) (treeStart next)
    && endsExpression prior
    && startsStatement next

endsExpression :: Tree -> Bool
endsExpression (Group _ _ _) = True
endsExpression (Atom leaf) = case leafKind leaf of
  Name -> True
  Literal -> True
  Word -> leafText leaf `elem` ["this", "super", "null", "true", "false", "undefined"]
  Symbol -> leafText leaf `elem` ["++", "--"]

startsStatement :: Tree -> Bool
startsStatement (Group open _ _) = leafText open == "{"
startsStatement (Atom leaf) = case leafKind leaf of
  Name -> True
  Word -> leafText leaf `notElem` ["in", "instanceof", "of", "as", "satisfies", "extends", "implements", "is", "keyof"]
  Literal -> maybe False (isDigit . fst) (T.uncons (leafText leaf))
  Symbol -> leafText leaf `elem` ["'", "\"", "@", "!", "++", "--", "#"]

-- | The statement-level declaration that starts here, if any: the nodes it
-- contributes and the trees after it.
declarationAt :: Context -> [Tree] -> Maybe ([Node], [Tree])
declarationAt context trees = case trees of
  Atom first : rest
    | leafText first == "async",
      Atom function : more <- rest,
      isWord "function" (Atom function) ->
        functionDeclaration (leafStart first) more
    | isWord "function" (Atom first) -> functionDeclaration (leafStart first) rest
    | isWord "class" (Atom first) -> classDeclaration (leafStart first) rest
    | leafText first == "@" -> decorated (leafStart first) rest
    | any (`isWord` Atom first) ["const", "let", "var"],
      typed context,
      Atom enum : more <- rest,
      leafText enum == "enum" ->
        enumDeclaration (leafStart first) more
    | any (`isWord` Atom first) ["const", "let", "var"] ->
        let (declarators, remaining) = statementTrees context rest
         in Just (variableDeclarators context declarators, remaining)
    | isWord "import" (Atom first) -> importStatement first rest
    | typed context, isWord "enum" (Atom first) -> enumDeclaration (leafStart first) rest
    | typed context,
      leafKind first == Word,
      leafText first == "interface",
      Atom name' : _ <- rest,
      Just n <- leafName name' ->
        let (header, after) = break (isGroup "{") rest
         in case after of
              body : remaining -> Just ([declaration (leafStart first) (treeEnd body) "interface_declaration" n True], remaining)
              [] -> Just ([], drop (length header) rest)
    | typed context,
      leafKind first == Word,
      leafText first == "type",
      Atom name' : _ <- rest,
      Just n <- leafName name' ->
        let (alias, remaining) = statementTrees context rest
         in Just ([declaration (leafStart first) (endOf (Atom first : alias)) "type_alias_declaration" n True], remaining)
  _ -> Nothing
  where
    functionDeclaration start rest = case rest of
      Atom name' : more
        | Just n <- leafName name' ->
            let (signature, after) = break (isGroup "(") more
             in case after of
                  parameters : afterParameters -> case bodyOf afterParameters of
                    Just (returnType, body, remaining) ->
                      Just
                        ( declaration start (treeEnd body) "function_declaration" n False
                            : concatMap (nested context) (signature ++ [parameters] ++ returnType ++ [body]),
                          remaining
                        )
                    Nothing -> Nothing
                  [] -> Nothing
      _ -> Nothing
    -- A body follows the parameters and an optional return type; an
    -- object type follows a colon or a type operator.
    bodyOf = search [] Nothing
      where
        search _ _ [] = Nothing
        search acc prior (tree : rest)
          | isAtom ";" tree = Nothing
          | isGroup "{" tree,
            maybe True (\p -> not (any (`isAtom` p) [":", "|", "&", "=>", ",", "<"])) prior =
              Just (reverse acc, tree, rest)
          | otherwise = search (tree : acc) (Just tree) rest
    classDeclaration start rest = case rest of
      Atom name' : more
        | Just n <- leafName name',
          Just (header, body, remaining) <- classBody more ->
            Just
              ( declaration start (treeEnd body) "class_declaration" n True
                  : concatMap (nested context) header
                  ++ nested context body,
                remaining
              )
      _ -> Nothing
    classBody = search [] Nothing
      where
        search _ _ [] = Nothing
        search acc prior (tree : rest)
          | isAtom ";" tree = Nothing
          | isGroup "{" tree,
            maybe True (\p -> not (any (`isAtom` p) ["<", ","]) && not (isWord "extends" p) && not (isWord "implements" p)) prior =
              Just (reverse acc, tree, rest)
          | otherwise = search (tree : acc) (Just tree) rest
    -- Decorators belong to the class they precede.
    decorated start rest =
      let after = skipDecorator rest
       in case after of
            Atom at : more | leafText at == "@" -> decorated start more
            Atom class' : more | isWord "class" (Atom class') -> classDeclaration start more
            _ -> Nothing
    skipDecorator (Atom _ : Atom dot : more) | leafText dot == "." = skipDecorator more
    skipDecorator (Atom _ : arguments : more) | isGroup "(" arguments = more
    skipDecorator (_ : more) = more
    skipDecorator [] = []
    enumDeclaration start rest = case rest of
      Atom name' : body : remaining
        | Just n <- leafName name',
          isGroup "{" body ->
            Just ([declaration start (treeEnd body) "enum_declaration" n True], remaining)
      _ -> Nothing
    importStatement first rest = case rest of
      next : _ | isGroup "(" next || isAtom "." next -> Nothing
      _ ->
        let (clause, remaining) = statementTrees context rest
            end = endOf (Atom first : clause) + (if take 1 remaining' == [";"] then 1 else 0)
            remaining' = [t | Just t <- [atomText =<< firstOf remaining]]
            sourceAt = case break (isWord "from") clause of
              (_, _ : quote : _) -> Just quote
              _ -> case clause of
                quote : _ | isAtom "'" quote || isAtom "\"" quote -> Just quote
                _ -> Nothing
            node fact = Node (leafStart first) end 0 fact
         in Just $ case sourceAt of
              Just quote
                | not (any (isAtom "=") clause),
                  isAtom "'" quote || isAtom "\"" quote ->
                    ([node (ImportFact (stripQuotes (stringText quote clause)))], remaining)
              _ -> ([node (LimitFact ("Unresolved import syntax at line " <> T.pack (show (lineAt (table context) (leafStart first)))))], remaining)
    stringText quote clause =
      let fromQuote = dropWhile (\t -> treeStart t /= treeStart quote) clause
       in case drop 1 fromQuote of
            more -> case [t | t <- more, atomText t == atomText quote] of
              close : _ -> slice (text context) (treeStart quote) (treeEnd close)
              [] -> ""
    stripQuotes value =
      let dropped = if T.take 1 value `elem` ["'", "\""] then T.drop 1 value else value
       in if T.takeEnd 1 dropped `elem` ["'", "\""] then T.dropEnd 1 dropped else dropped

firstOf :: [a] -> Maybe a
firstOf (x : _) = Just x
firstOf [] = Nothing

endOf :: [Tree] -> Int
endOf [] = 0
endOf trees = treeEnd (last trees)

-- | The trees of the statement that starts here (without its semicolon),
-- and the trees after it.
statementTrees :: Context -> [Tree] -> ([Tree], [Tree])
statementTrees context = go Nothing []
  where
    go _ acc [] = (reverse acc, [])
    go prior acc (tree : rest)
      | isAtom ";" tree = (reverse acc, rest)
      | Just p <- prior, asi context p tree = (reverse acc, tree : rest)
      | otherwise = go (Just tree) (tree : acc) rest

-- | The declarators of a var, let or const declaration.
variableDeclarators :: Context -> [Tree] -> [Node]
variableDeclarators context = concatMap declarator . split 0 False []
  where
    -- Split at top-level commas; generic arguments in a type annotation
    -- hold commas of their own.
    split :: Int -> Bool -> [Tree] -> [Tree] -> [[Tree]]
    split _ _ acc [] = [reverse acc]
    split depth annotated acc (tree : rest)
      | isAtom "," tree, depth == 0 = reverse acc : split 0 False [] rest
      | not annotated,
        isAtom "<" tree,
        Atom prior : _ <- acc,
        isJust (leafName prior),
        Just (arguments, after) <- typeArguments (1 :: Int) [] rest =
          split depth annotated (reverse arguments ++ tree : acc) after
      | annotated, isAtom "<" tree = split (depth + 1) annotated (tree : acc) rest
      | annotated, isAtom ">" tree = split (max 0 (depth - 1)) annotated (tree : acc) rest
      | isAtom ":" tree, null (drop 1 acc) || not (any (isAtom "=") acc) = split depth True (tree : acc) rest
      | isAtom "=" tree = split 0 False (tree : acc) rest
      | otherwise = split depth annotated (tree : acc) rest
    -- Type arguments of a call: a matching > followed by the arguments.
    typeArguments _ _ [] = Nothing
    typeArguments n acc (tree : rest)
      | isAtom ">" tree,
        n == 1 = case rest of
          next : _ | isGroup "(" next -> Just (reverse (tree : acc), rest)
          _ -> Nothing
      | isAtom ">" tree = typeArguments (n - 1) (tree : acc) rest
      | isAtom "<" tree = typeArguments (n + 1) (tree : acc) rest
      | any (`isAtom` tree) [";", "=", "&&", "||"] = Nothing
      | otherwise = typeArguments n (tree : acc) rest
    declarator [] = []
    declarator trees@(pattern' : rest) =
      let named = case pattern' of
            Atom leaf -> leafName leaf
            Group _ _ _ -> Just (treeText (text context) pattern')
       in case named of
            Just n -> declaration (treeStart pattern') (endOf trees) "variable_declarator" n False : nested context pattern' ++ scan context False rest
            Nothing -> scan context False trees
