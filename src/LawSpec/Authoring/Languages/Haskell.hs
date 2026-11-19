-- | Haskell declarations, imports and module names for authoring advice:
-- the @data_type@, @newtype@, @type_synomym@ (the grammar's spelling),
-- @function@ and @bind@ nodes of the Haskell grammar at any depth (top
-- level, class and instance bodies, where and let blocks), the module of
-- the @header@ and of each @import@. Declarations are found by the layout
-- rule: a block opened by where, let, do, of or \\case holds the items that
-- start on its column; explicit braces separate items by semicolons.
--
-- Haddock comments, pragmas and CPP lines are leaves, as the grammar keeps
-- them (only plain comments are dropped), but they take no part in layout.
-- An equation is a @function@ when its name has argument patterns, else a
-- @bind@; an infix definition (a \`op\` b, a <> b) names nothing, as in
-- the grammar.
--
-- Limits: the layout rule's parse-error(t) case is approximated (a block
-- also ends at the @in@ of an enclosing let); data and type families and
-- instances, pattern synonyms and Template Haskell declarations are not
-- recognised as declarations.
-- ref:DEC-authoring-advisories
module LawSpec.Authoring.Languages.Haskell (facts) where

import Control.Monad (void)
import Data.Char (isAlphaNum, isLower, isSpace, isUpper)
import qualified Data.IntSet as IS
import Data.Text (Text)
import qualified Data.Text as T
import LawSpec.Authoring.Syntax
import Text.Megaparsec
import Text.Megaparsec.Char (char, string)

facts :: Text -> Facts
facts source = case lexSource space (step table) source of
  Left problem -> unreadable problem
  Right leaves ->
    let code = filter (not . extra) leaves
     in case brackets [("(", ")"), ("[", "]"), ("{", "}")] code of
          Left problem -> unreadable problem
          Right trees ->
            let starts = lineStarts table code
             in assemble source leaves (topLevel source table starts trees)
  where
    table = position source
    unreadable problem = failed ("Native syntax could not be read: " <> T.pack problem)

-- | Haddock comments, pragmas and CPP lines: leaves outside the layout.
extra :: Leaf -> Bool
extra leaf =
  leafKind leaf == Literal
    && any (`T.isPrefixOf` leafText leaf) ["--", "{-", "#"]

-- | The offsets of the leaves that start their lines.
lineStarts :: Position -> [Leaf] -> IS.IntSet
lineStarts table leaves =
  IS.fromList
    [ leafStart leaf
    | (previous, leaf) <- zip (Nothing : map Just leaves) leaves,
      maybe True (\p -> lineAt table (leafEnd p) < lineAt table (leafStart leaf)) previous
    ]

symbolChar :: Char -> Bool
symbolChar c = c `elem` ("!#$%&*+./<=>?@\\^|-~:" :: String)

-- | Whitespace and plain comments; haddock comments are leaves.
space :: Lexer ()
space = skipMany (void (takeWhile1P Nothing isSpace) <|> try plainLine <|> try plainBlock)
  where
    plainLine = do
      notFollowedBy haddockLine
      dashes
      void (takeWhileP Nothing (/= '\n'))
    plainBlock = do
      notFollowedBy (string "{-#")
      notFollowedBy haddockBlockStart
      blockComment True "{-" "-}"

-- | Two or more dashes not followed by a symbol: a line comment's start.
dashes :: Lexer ()
dashes = do
  _ <- string "--"
  _ <- takeWhileP Nothing (== '-')
  notFollowedBy (satisfy symbolChar)

haddockLine :: Lexer ()
haddockLine = do
  dashes
  _ <- takeWhileP Nothing (\c -> c == ' ' || c == '\t')
  void (satisfy (`elem` ("|^" :: String)))

haddockBlockStart :: Lexer ()
haddockBlockStart = void (string "{-" *> takeWhileP Nothing isSpace *> satisfy (`elem` ("|^" :: String)))

step :: Position -> Maybe Leaf -> Lexer [Leaf]
step table previous =
  (: [])
    <$> choice
      [ try haddock,
        try (plain blockHaddock),
        try (plain pragma),
        try cpp,
        try (plain stringLiteral),
        try (plain characterLiteral),
        plain numberLike,
        identifier previous,
        operator
      ]
  where
    -- A haddock comment, with the line comments that follow it from the
    -- first column.
    haddock = do
      start <- getOffset
      _ <- lookAhead haddockLine
      first <- takeWhileP Nothing (/= '\n')
      more <- many (try (char '\n' *> lookAhead dashes *> takeWhileP Nothing (/= '\n')))
      end <- getOffset
      pure (Leaf Literal (T.intercalate "\n" (first : more)) Nothing start end)
    blockHaddock = do
      _ <- lookAhead (try haddockBlockStart)
      fst <$> match (blockComment True "{-" "-}")
    pragma = do
      _ <- string "{-#"
      body <- manyTill anySingle (string "#-}")
      pure ("{-#" <> T.pack body <> "#-}")
    cpp = do
      offset <- getOffset
      if columnAt table offset /= 0 then fail "not a CPP line" else pure ()
      plain (T.cons <$> char '#' <*> takeWhileP Nothing (/= '\n'))

stringLiteral :: Lexer Text
stringLiteral = do
  _ <- char '"'
  body <- many (try (T.cons <$> char '\\' <*> (T.singleton <$> anySingle)) <|> takeWhile1P Nothing (\c -> c /= '"' && c /= '\\' && c /= '\n'))
  _ <- char '"'
  pure ("\"" <> T.concat body <> "\"")

characterLiteral :: Lexer Text
characterLiteral = do
  _ <- char '\''
  body <-
    (T.cons <$> char '\\' <*> takeWhile1P Nothing (/= '\''))
      <|> (T.singleton <$> satisfy (/= '\''))
  _ <- char '\''
  pure ("'" <> body <> "'")

keywords :: [Text]
keywords =
  ["case", "class", "data", "default", "deriving", "do", "else", "foreign", "if", "import", "in", "infix", "infixl", "infixr", "instance", "let", "module", "newtype", "of", "then", "type", "where", "_", "forall", "mdo", "rec"]

-- | A name: a variable or constructor, or a module qualifier (followed
-- directly by a dot and a name), which is not a name to the advice.
identifier :: Maybe Leaf -> Lexer Leaf
identifier _ = do
  start <- getOffset
  text <- identifierWith (\c -> isLower c || isUpper c || c == '_') (\c -> isAlphaNum c || c == '_' || c == '\'')
  end <- getOffset
  qualifier <-
    if maybe False isUpper (fmap fst (T.uncons text))
      then option False (True <$ lookAhead (try (char '.' *> satisfy (\c -> isLower c || isUpper c || c == '_' || symbolChar c))))
      else pure False
  let keyword = text `elem` keywords || qualifier
      -- Constructors and type names are kept apart from variables in the
      -- fingerprint, as the grammar's leaf types keep them.
      kind = if keyword || maybe False (isUpper . fst) (T.uncons text) then Word else Name
  pure (Leaf kind text (if keyword then Nothing else Just text) start end)

-- | An operator; one starting with a colon is a constructor operator,
-- which the grammar counts among names.
operator :: Lexer Leaf
operator = do
  start <- getOffset
  text <-
    choice
      [ T.singleton <$> satisfy (`elem` ("()[]{},;`" :: String)),
        T.pack <$> some (satisfy symbolChar),
        T.singleton <$> anySingle
      ]
  end <- getOffset
  let constructor = ":" `T.isPrefixOf` text && text `notElem` ["::", ":"] || text == ":"
  pure (Leaf Symbol text (if constructor && text /= "::" then Just text else Nothing) start end)

-- | What an item of a block declares: a declaration, a class or instance
-- member, a do statement (which may bind), or nothing of its own (case
-- alternatives and bracketed expressions).
data Mode = Declarations | ClassBody | Statements | Expressions
  deriving (Eq)

topLevel :: Text -> Position -> IS.IntSet -> [Tree] -> [Node]
topLevel source table starts trees = case trees of
  first : rest
    | isAtom "module" first ->
        let (header, after) = break (isAtom "where") rest
            moduleName = takeWhile (not . isGroup "(") header
            headerNode = case after of
              whereTree : _ ->
                [Node (treeStart first) (treeEnd whereTree) 0 (ModuleFact (spanText source moduleName)) | not (null moduleName)]
                  ++ keywordsIn moduleName
                  ++ concat [exportModules inner | Group _ inner _ <- header]
              [] -> []
         in headerNode ++ fst (layout (drop 1 after))
  _ -> fst (layout trees)
  where
    layout = block source table starts Declarations False (-1)

-- | Every name leaf among the trees, read as a keyword (module names).
keywordsIn :: [Tree] -> [Node]
keywordsIn trees = [Node (leafStart l) (leafEnd l) 0 KeywordFact | t <- trees, l <- treeLeaves t, leafName l /= Nothing]

-- | module M re-exports in an export list.
exportModules :: [Tree] -> [Node]
exportModules = go
  where
    go (keyword : rest)
      | isAtom "module" keyword =
          let (moduleName, more) = break (\t -> isAtom "," t) rest
           in keywordsIn moduleName ++ go more
    go (_ : rest) = go rest
    go [] = []

spanText :: Text -> [Tree] -> Text
spanText _ [] = ""
spanText source trees@(first : _) = slice source (treeStart first) (treeEnd (last trees))

column :: Position -> Tree -> Int
column table tree = columnAt table (treeStart tree)

-- | A layout block from its first tree: its items' nodes, and the trees
-- after it (from the tree that ends it). Explicit braces hold their items
-- between semicolons.
block :: Text -> Position -> IS.IntSet -> Mode -> Bool -> Int -> [Tree] -> ([Node], [Tree])
block source table starts mode inLet enclosing trees = case trees of
  Group open inner _ : rest
    | leafText open == "{" ->
        (concat [fst (item source table starts mode False (-1) trees') | trees' <- statements (isAtom ";") inner], rest)
  first : _
    -- A block no deeper than the one around it is empty.
    | column table first <= enclosing,
      IS.member (treeStart first) starts ->
        ([], trees)
    | otherwise -> items (column table first) trees
  [] -> ([], [])
  where
    items indentation remaining = case remaining of
      [] -> ([], [])
      next : _
        | endsBlock indentation next -> ([], remaining)
        | otherwise ->
            let (nodes, rest) = item source table starts mode inLet indentation remaining
                (more, after) = items indentation rest
             in (nodes ++ more, after)
    endsBlock indentation next =
      (IS.member (treeStart next) starts && column table next < indentation)
        || (inLet && isAtom "in" next)

-- | One item of a block at the given indentation: the trees up to the next
-- tree that starts a line at or left of it (or an enclosing let's in). The
-- item's own trees exclude those of the blocks nested in it.
item :: Text -> Position -> IS.IntSet -> Mode -> Bool -> Int -> [Tree] -> ([Node], [Tree])
item source table starts mode inLet indentation trees = case trees of
  [] -> ([], [])
  _ : _ ->
    let (consumed, own, nested, remaining) = collect [] [] [] trees
        itemTrees = reverse consumed
        ownTrees = reverse own
        end = maybe 0 treeEnd (lastOf itemTrees)
        declared = case mode of
          Declarations -> declarationOf source True ownTrees end
          ClassBody -> declarationOf source False ownTrees end
          Statements -> doBind ownTrees end
          Expressions -> []
     in (declared ++ annotations ownTrees ++ nested, remaining)
  where
    collect acc own nodes [] = (acc, own, nodes, [])
    collect acc own nodes remaining@(next : rest)
      | not (null acc),
        IS.member (treeStart next) starts && column table next <= indentation =
          (acc, own, nodes, remaining)
      | inLet && isAtom "in" next = (acc, own, nodes, remaining)
      -- A semicolon separates items in a layout block too.
      | isAtom ";" next, indentation >= 0 = (acc, own, nodes, rest)
      | Just (innerMode, innerLet) <- opens (reverse own) next =
          let (inner, after) = block source table starts innerMode (innerLet || inLet) indentation rest
              consumedInner = takeWhile (`before` after) rest
           in case after of
                -- A let block ends at its in, which belongs to the let.
                inTree : more
                  | innerLet && isAtom "in" inTree ->
                      collect (inTree : reverse consumedInner ++ next : acc) (inTree : next : own) (nodes ++ inner) more
                _ -> collect (reverse consumedInner ++ next : acc) (next : own) (nodes ++ inner) after
      | otherwise = collect (next : acc) (next : own) (nodes ++ nestedGroups next) rest
    before tree after = case after of
      a : _ -> treeStart tree < treeStart a
      [] -> True
    -- A group's contents are an expression of their own.
    nestedGroups (Group _ inner _) = fst (item source table starts Expressions False (-1) inner)
    nestedGroups _ = []
    opens own keyword = case atomText keyword of
      Just "where"
        | any (\t -> isAtom "class" t || isAtom "instance" t) (take 2 own) -> Just (ClassBody, False)
        | otherwise -> Just (Declarations, False)
      Just "let" -> Just (Declarations, True)
      Just text | text `elem` ["do", "mdo", "rec"] -> Just (Statements, False)
      Just "of" -> Just (Expressions, False)
      Just text
        | text `elem` ["case", "cases"],
          maybe False (isAtom "\\") (lastOf own) ->
            Just (Expressions, False)
      _ -> Nothing

lastOf :: [a] -> Maybe a
lastOf [] = Nothing
lastOf xs = Just (last xs)

-- | A do statement that binds (pattern <- expression): the grammar's
-- @bind@, named by its pattern when that is a variable, else by its
-- expression when that is one.
doBind :: [Tree] -> Int -> [Node]
doBind trees end = case break (isAtom "<-") trees of
  (pattern@(first : _), _ : expression) -> case (variable pattern, variable expression) of
    (Just name', _) -> [declaration (treeStart first) end "bind" name' False]
    (_, Just name') -> [declaration (treeStart first) end "bind" name' False]
    _ -> []
  _ -> []

-- | A lone variable.
variable :: [Tree] -> Maybe Text
variable [Atom leaf]
  | Just name' <- leafName leaf,
    maybe False (\(c, _) -> isLower c || c == '_') (T.uncons name') =
      Just name'
variable _ = Nothing

-- | A lone variable or type constructor: what the grammar's name lookup
-- finds directly under a function type.
typeName :: [Tree] -> Maybe Text
typeName [Atom leaf]
  | Just name' <- leafName leaf,
    maybe False (\(c, _) -> c /= ':') (T.uncons name') =
      Just name'
typeName _ = Nothing

-- | The types after each :: among the trees (signatures and annotations),
-- each up to what ends it.
annotations :: [Tree] -> [Node]
annotations trees = case break (isAtom "::") trees of
  (_, _ : rest) ->
    let (typeRegion, after) = break stops rest
     in typeNodes typeRegion ++ annotations after
  _ -> []
  where
    stops t = any (`isAtom` t) ["=", ",", "where", "<-", ";", "|", "then", "else", "of", "in", "::"]

-- | The function types of a type: a @function@ node at each arrow,
-- spanning its parameter and the rest of the type, named by the parameter
-- when that is a lone name, or by the result when that is one and the
-- last; and those in its brackets.
typeNodes :: [Tree] -> [Node]
typeNodes typeRegion =
  let body = case break (isAtom ".") typeRegion of
        (Atom forall' : _, _ : after) | leafText forall' == "forall" -> after
        _ -> typeRegion
      contexts = statements (isAtom "=>") body
      main = maybe [] id (lastOf contexts)
      parts = statements (isAtom "->") main
      arity = length parts
      arrows =
        [ declaration (treeStart first) end "function" name' False
        | arity >= 2,
          end <- maybe [] (\lastPart -> maybe [] (pure . treeEnd) (lastOf lastPart)) (lastOf parts),
          (index, part@(first : _)) <- zip [0 :: Int ..] (take (arity - 1) parts),
          Just name' <- [nameOf index part]
        ]
      nameOf index part = case typeName part of
        Just name' -> Just name'
        Nothing | index == arity - 2 -> maybe Nothing typeName (lastOf parts)
        Nothing -> Nothing
   in arrows ++ concatMap groupTypes (concat parts)

groupTypes :: Tree -> [Node]
groupTypes (Group open inner _)
  | leafText open `elem` ["(", "["] = concatMap typeNodes (statements (isAtom ",") inner)
groupTypes _ = []

-- | The declaration an item is, if any: at the top level or in a let or
-- where block (with data and type declarations), or in a class or
-- instance body.
declarationOf :: Text -> Bool -> [Tree] -> Int -> [Node]
declarationOf source topLevel' trees end = case trees of
  [] -> []
  first : rest -> case atomText first of
    Just "import" | topLevel' -> importOf first rest
    Just "data" | topLevel' -> typeDeclaration "data_type" rest ++ fieldTypes rest
    Just "newtype" | topLevel' -> typeDeclaration "newtype" rest ++ fieldTypes rest
    Just "type"
      | topLevel',
        any (isAtom "=") rest ->
          typeDeclaration "type_synomym" rest ++ typeNodes (drop 1 (dropWhile (not . isAtom "=") rest))
    Just keyword
      | keyword `elem` ["class", "instance"] ->
          typeNodes (takeWhile (not . isAtom "where") rest)
    Just keyword | keyword `elem` ["data", "newtype", "type", "deriving", "default", "foreign", "infix", "infixl", "infixr", "pattern", "import"] -> []
    _ -> equation
  where
    start = maybe 0 treeStart (lastOf (take 1 trees))
    -- The bracketed types of a data or newtype declaration's constructors.
    fieldTypes rest = concatMap groupTypes (drop 1 (dropWhile (not . isAtom "=") rest))
    typeDeclaration kind rest = case rest of
      next : _
        | isAtom "family" next || isAtom "instance" next -> []
      _ ->
        let afterContext = case break (isAtom "=>") (takeWhile (\t -> not (isAtom "=" t || isAtom "where" t)) rest) of
              (_, _ : after) -> after
              _ -> rest
         in case [l | t <- take 1 afterContext, l <- treeLeaves t, leafName l /= Nothing] of
              nameLeaf : _ | maybe False (isUpper . fst) (T.uncons (leafText nameLeaf)) -> [declaration start end kind (leafText nameLeaf) True]
              _ -> []
    importOf keyword rest =
      let afterQualified = dropWhile (\t -> isAtom "qualified" t || isAtom "safe" t || isString t) rest
          moduleName = moduleTrees afterQualified
          remainder = drop (length moduleName) afterQualified
          keywordNodes =
            [Node (treeStart t) (treeEnd t) 0 KeywordFact | t <- rest, any (`isAtom` t) ["qualified", "as", "hiding", "safe"]]
              ++ keywordsIn moduleName
              ++ keywordsIn (takeWhile (not . isGroup "(") (drop 1 (dropWhile (not . isAtom "as") remainder)))
       in [Node (treeStart keyword) end 0 (ImportFact (spanText source moduleName)) | not (null moduleName)] ++ keywordNodes
    isString (Atom l) = "\"" `T.isPrefixOf` leafText l
    isString _ = False
    moduleTrees (t : Atom dot : more) | leafText dot == "." = t : Atom dot : moduleTrees more
    moduleTrees (t : _) = [t]
    moduleTrees [] = []
    -- An equation: the left-hand side before = or a guard.
    equation =
      let lhs = takeWhile (\t -> not (isAtom "=" t || isAtom "|" t)) trees
       in if any (isAtom "::") lhs || length lhs == length trees
            then []
            else case lhs of
              Atom head' : arguments
                | Just name' <- leafName head',
                  maybe False (\(c, _) -> isLower c || c == '_') (T.uncons name'),
                  not (isInfix arguments) ->
                    [declaration start end (if null arguments then "bind" else "function") name' False]
              operatorGroup@(Group open [Atom op] _) : arguments
                | leafText open == "(",
                  leafKind op == Symbol || maybe False (\(c, _) -> c == ':') (T.uncons (leafText op)),
                  not (isInfix arguments) ->
                    [declaration start end (if null arguments then "bind" else "function") (treeText source operatorGroup) False]
              _ -> []
    -- An operator after the name makes the definition infix, except a
    -- bang, lazy or type-application prefix written against its pattern.
    isInfix arguments = case arguments of
      Atom op : next : _
        | leafText op == "`" -> True
        | isOperator op -> not (prefixPattern op next)
      _ -> False
    isOperator op = leafKind op == Symbol && T.all symbolChar (leafText op) || ":" `T.isPrefixOf` leafText op && T.all symbolChar (leafText op)
    prefixPattern op next = leafText op `elem` ["!", "~", "@"] && leafEnd op == treeStart next
