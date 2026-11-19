-- | C# declarations and namespaces for authoring advice. Recognised: class,
-- record (including record class and record struct), struct, interface
-- and enum declarations and method declarations in their bodies, at any
-- nesting of namespaces and types; block and file-scoped namespace names
-- as module names; and #if regions, an unsupported construct. Using
-- directives are not imports, as in the advice before. Local functions,
-- constructors, operators, properties, delegates and top-level statements
-- declare nothing here. Limits: a region selected by #if is read as code
-- whatever its condition, so a declaration split across #if branches can
-- leave its brackets unbalanced, which reads as incomplete; the custom
-- delimiters of $$-interpolated raw strings are not recognised.
-- ref:DEC-authoring-advisories
module LawSpec.Authoring.Languages.CSharp (facts) where

import Data.Char (isAlpha, isAlphaNum, isDigit, isSpace)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import LawSpec.Authoring.Syntax
import Text.Megaparsec
import Text.Megaparsec.Char (char, string)

facts :: Text -> Facts
facts source = case csharpLeaves source of
  Left problem -> unreadable problem
  Right leaves -> case brackets [("(", ")"), ("[", "]"), ("{", "}")] (filter (not . (`elem` directiveLines leaves) . lineAt table . leafStart) leaves) of
    Left problem -> unreadable problem
    Right trees -> assemble source leaves (body source trees ++ conditions table leaves ++ discards trees)
  where
    table = position source
    unreadable problem = failed ("Native syntax could not be read: " <> T.pack problem)
    -- A directive's line is not code.
    directiveLines leaves = [lineAt table (leafStart leaf) | leaf <- leaves, leafKind leaf == Word, T.isPrefixOf "#" (leafText leaf)]

-- | A discard in a deconstruction (var (x, _)) is no name.
discards :: [Tree] -> [Node]
discards trees = case trees of
  [] -> []
  Atom var : Group _ inner _ : more
    | leafText var == "var" ->
        [Node (leafStart l) (leafEnd l) 0 KeywordFact | Atom l <- inner, leafText l == "_"] ++ discards inner ++ discards more
  Group _ inner _ : more -> discards inner ++ discards more
  _ : more -> discards more

-- | #if regions: from each #if to its #endif.
conditions :: Position -> [Leaf] -> [Node]
conditions table = go []
  where
    go _ [] = []
    go open (leaf : rest)
      | leafText leaf == "#if" = go (leaf : open) rest
      | leafText leaf == "#endif",
        start : open' <- open =
          Node (leafStart start) (leafEnd leaf) 0 (LimitFact ("Unsupported preproc_if at line " <> T.pack (show (lineAt table (leafStart start)))))
            : go open' rest
      | otherwise = go open rest

csharpLeaves :: Text -> Either String [Leaf]
csharpLeaves = lexSource (spaces [lineComment "//", blockComment False "/*" "*/"]) step
  where
    step previous =
      choice
        [ (: []) <$> try (directiveAt previous),
          try rawString,
          try interpolated,
          (: []) <$> try (plain verbatim),
          delimited (string "\"") (string "\"") [escape] (\c -> c == '\\' || c == '"'),
          try characterLiteral,
          (: []) <$> plain number,
          (: []) <$> identifier previous,
          (: []) <$> symbol (operatorFrom operators <|> (T.singleton <$> anySingle))
        ]
    -- A preprocessor directive word (#if, #endif, #region, ...), kept out
    -- of the brackets; the rest of its line is ordinary leaves.
    directiveAt _ = do
      start <- getOffset
      _ <- char '#'
      _ <- takeWhileP Nothing (\c -> c == ' ' || c == '\t')
      text <- takeWhile1P Nothing isAlpha
      end <- getOffset
      pure (Leaf Word ("#" <> text) Nothing start end)
    rawString = do
      start <- getOffset
      dollars <- takeWhileP Nothing (== '$')
      quotes <- takeWhileP Nothing (== '"')
      if T.length quotes < 3
        then fail "not a raw string"
        else do
          middle <- getOffset
          let opening
                | T.null dollars = [Leaf Literal quotes Nothing start middle]
                | otherwise = [Leaf Literal dollars Nothing start (start + T.length dollars), Leaf Literal quotes Nothing (start + T.length dollars) middle]
          content <- many (try (notFollowedBy (string quotes) *> interpolationIf (not (T.null dollars))) <|> ((: []) <$> plain (rawContent quotes (not (T.null dollars)))))
          final <- plain (string quotes)
          pure (opening ++ concat content ++ [final])
    rawContent quotes interpolating =
      T.pack <$> some (notFollowedBy (string quotes) *> satisfy (\c -> not interpolating || c /= '{'))
    interpolationIf True = interpolation
    interpolationIf False = fail "no interpolation"
    interpolated = do
      prefix <- plain (string "$@" <|> string "@$" <|> string "$")
      let verbatim' = T.length (leafText prefix) == 2
      open <- symbol (string "\"")
      content <-
        many
          ( try ((: []) <$> plain (string "{{" <|> string "}}"))
              <|> interpolation
              <|> (if verbatim' then (: []) <$> plain (string "\"\"") else escape)
              <|> ((: []) <$> plain (takeWhile1P Nothing (\c -> c `notElem` ("{}\"\\" :: String) || (verbatim' && c == '\\'))))
          )
      close <- symbol (string "\"")
      pure ([prefix, open] ++ concat content ++ [close])
    -- { expression [, alignment] [: format] }: the format is not a leaf.
    interpolation = do
      open <- plain (string "{")
      inner <- code (0 :: Int)
      pure (open : inner)
    code depth = do
      _ <- takeWhileP Nothing isSpace
      next <- lookAhead anySingle
      case next of
        '}' | depth == 0 -> (: []) <$> plain (string "}")
        ':' | depth == 0 -> do
          colon <- symbol (string ":")
          _ <- takeWhileP Nothing (/= '}')
          close <- plain (string "}")
          pure [colon, close]
        _ -> do
          leaves <- step Nothing
          let change = sum [delta (leafText l) | l <- leaves, leafKind l == Symbol]
          (leaves ++) <$> code (depth + change)
    delta t
      | t `elem` ["(", "[", "{"] = 1
      | t `elem` [")", "]", "}"] = -1
      | otherwise = 0 :: Int
    verbatim = do
      _ <- char '@'
      _ <- char '"'
      content <- many (string "\"\"" <|> (T.singleton <$> satisfy (/= '"')))
      _ <- char '"'
      pure ("@\"" <> T.concat content <> "\"")
    characterLiteral = do
      open <- symbol (string "'")
      inside <- escape <|> ((: []) <$> plain (T.singleton <$> satisfy (/= '\'')))
      close <- symbol (string "'")
      pure ([open] ++ inside ++ [close])
    number = do
      first <- satisfy isDigit
      rest <-
        many
          ( try
              ( do
                  e <- satisfy (`elem` ("eE" :: String))
                  sign <- satisfy (`elem` ("+-" :: String))
                  digit <- satisfy isDigit
                  pure (T.pack [e, sign, digit])
              )
              <|> try (T.cons <$> char '.' <*> (T.singleton <$> satisfy isDigit))
              <|> (T.singleton <$> satisfy (\c -> isAlphaNum c || c == '_'))
          )
      pure (T.concat (T.singleton first : rest))
    identifier previous = do
      start <- getOffset
      at <- optional (char '@')
      text <- identifierWith (\c -> isAlpha c || c == '_') (\c -> isAlphaNum c || c == '_')
      end <- getOffset
      next <- lookAhead (takeWhileP Nothing isSpace *> optional (try (string "=>") <|> (T.singleton <$> anySingle)))
      let full = maybe "" T.singleton at <> text
          modifier = text `elem` ["partial", "required"] && maybe False (T.all isAlpha) next && next /= Nothing
          accessor =
            text `elem` ["get", "set", "init", "add", "remove"]
              && next `elem` map Just [";", "{", "=>"]
              && maybe True (\l -> leafText l `elem` ["{", ";", "}", "]"] || leafText l `elem` modifiers) previous
          -- A discard pattern (case _, _ => in a switch or a lambda) is no
          -- name; a discarded argument (out _) is.
          discard = text == "_" && (next == Just "=>" || fmap leafText previous == Just "case")
          pattern = text `elem` ["not", "and", "or"] && fmap leafText previous `elem` map Just ["is", "not", "and", "or", "case"]
          keyword = at == Nothing && (text `elem` reserved || modifier || accessor || discard || pattern)
          -- The grammar's namespace keyword is a leaf whose type mentions
          -- a name, so it counts among the identifiers.
          naming
            | text == "namespace" = Just text
            | keyword = Nothing
            | otherwise = Just full
      pure (Leaf (if keyword then Word else Name) full naming start end)
    operators = ["=>", "??=", "??", "?.", "::", "->", "==", "!=", "<=", "&&", "||", "++", "--", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<", "<<="]

reserved :: [Text]
reserved =
  [ "abstract",
    "as",
    "base",
    "bool",
    "break",
    "byte",
    "case",
    "catch",
    "char",
    "checked",
    "class",
    "const",
    "continue",
    "decimal",
    "default",
    "delegate",
    "do",
    "double",
    "else",
    "enum",
    "event",
    "explicit",
    "extern",
    "false",
    "finally",
    "fixed",
    "float",
    "for",
    "foreach",
    "goto",
    "if",
    "implicit",
    "in",
    "int",
    "interface",
    "internal",
    "is",
    "lock",
    "long",
    "namespace",
    "new",
    "null",
    "object",
    "operator",
    "out",
    "override",
    "params",
    "private",
    "protected",
    "public",
    "readonly",
    "ref",
    "return",
    "sbyte",
    "sealed",
    "short",
    "sizeof",
    "stackalloc",
    "static",
    "string",
    "struct",
    "switch",
    "this",
    "throw",
    "true",
    "try",
    "typeof",
    "uint",
    "ulong",
    "unchecked",
    "unsafe",
    "ushort",
    "using",
    "virtual",
    "void",
    "volatile",
    "while",
    "nint",
    "nuint",
    "var",
    "async",
    "await",
    "yield",
    "where",
    "global",
    "notnull",
    "when",
    "unmanaged",
    "file",
    "scoped",
    "from",
    "select",
    "into",
    "orderby",
    "join",
    "on",
    "equals",
    "by",
    "let",
    "ascending",
    "descending",
    "group"
  ]

modifiers :: [Text]
modifiers = ["public", "private", "protected", "internal", "static", "sealed", "abstract", "virtual", "override", "readonly", "unsafe", "partial", "new", "extern", "async", "file", "required", "volatile", "const", "ref", "fixed"]

-- | A namespace or type body, or the top level.
body :: Text -> [Tree] -> [Node]
body source = concatMap member . splitMembers
  where
    member trees@(first : rest)
      | isAtom "namespace" first =
          let (path, after) = break (\t -> isGroup "{" t || isAtom ";" t) rest
           in case after of
                Group _ inner close : _ ->
                  Node (treeStart first) (leafEnd close) 0 (ModuleFact (spanText source path)) : body source inner
                semicolon : _ -> [Node (treeStart first) (treeEnd semicolon) 0 (ModuleFact (spanText source path))]
                [] -> []
      | Just _ <- typeKeyword trees = typeDeclaration source trees
      | Just node <- method trees = [node]
    member _ = []
    method trees@(first : _) =
      let signature = stripModifiers trees
       in case findParameters [] signature of
            Just (before, rest)
              | length before >= 2,
                not (any (\t -> isAtom "=" t || isAtom "~" t || isAtom "delegate" t || isAtom "operator" t || isAtom "this" t) before),
                Just name' <- methodName before ->
                  let arrow = any (isAtom "=>") rest
                      end = case [t | t <- rest, (not arrow && isGroup "{" t) || isAtom ";" t] of
                        terminator : _ -> treeEnd terminator
                        [] -> treeEnd (last trees)
                   in Just (declaration (treeStart first) end "method_declaration" name' False)
            _ -> Nothing
    method [] = Nothing
    -- The parameter list: the first parenthesis group after a name or a
    -- type parameter list.
    findParameters _ [] = Nothing
    findParameters acc (tree : rest)
      | isGroup "(" tree,
        (previous : _) <- acc,
        isName previous || isAtom ">" previous =
          Just (reverse acc, rest)
      | isAtom "=" tree || isAtom "=>" tree || isGroup "{" tree = Nothing
      | otherwise = findParameters (tree : acc) rest
    methodName before = case reverse (dropTypeArguments (reverse before)) of
      [] -> Nothing
      trees -> case last trees of
        Atom leaf -> leafName leaf
        _ -> Nothing
    isName (Atom leaf) = leafKind leaf == Name
    isName _ = False

-- | Without a trailing type parameter list (given reversed).
dropTypeArguments :: [Tree] -> [Tree]
dropTypeArguments (Atom leaf : rest) | leafText leaf == ">" = opening (1 :: Int) rest
  where
    opening 0 trees = trees
    opening _ [] = []
    opening depth (Atom l : more)
      | leafText l == ">" = opening (depth + 1) more
      | leafText l == "<" = opening (depth - 1) more
    opening depth (_ : more) = opening depth more
dropTypeArguments trees = trees

spanText :: Text -> [Tree] -> Text
spanText _ [] = ""
spanText source trees@(first : _) = slice source (treeStart first) (treeEnd (last trees))

-- | When a sequence starts a type declaration (after its attributes and
-- modifiers), its keyword.
typeKeyword :: [Tree] -> Maybe Text
typeKeyword trees = case stripModifiers trees of
  Atom keyword : Atom kind : Atom name' : _
    | leafText keyword == "record",
      leafText kind `elem` ["class", "struct"],
      Just _ <- leafName name' ->
        Just "record"
  Atom keyword : Atom name' : _
    | leafText keyword `elem` ["class", "interface", "enum", "struct", "record"],
      Just _ <- leafName name' ->
        Just (leafText keyword)
  _ -> Nothing

typeDeclaration :: Text -> [Tree] -> [Node]
typeDeclaration _ [] = []
typeDeclaration source trees@(first : _) = case stripModifiers trees of
  Atom keyword : rest ->
    let afterKind = case rest of
          Atom kind : more | leafText keyword == "record" && leafText kind `elem` ["class", "struct"] -> more
          _ -> rest
     in case afterKind of
          Atom name' : afterName ->
            let recordKeyword = [Node (leafStart keyword) (leafEnd keyword) 0 KeywordFact | leafText keyword == "record"]
                (_, after) = break (\t -> isGroup "{" t || isAtom ";" t) afterName
                kind = case leafText keyword of
                  "class" -> "class_declaration"
                  "interface" -> "interface_declaration"
                  "enum" -> "enum_declaration"
                  "struct" -> "struct_declaration"
                  _ -> "record_declaration"
                node end = declaration (treeStart first) end kind (fromMaybe "" (leafName name')) True
             in case after of
                  Group _ inner close : more ->
                    let end = case more of
                          semicolon : _ | isAtom ";" semicolon -> treeEnd semicolon
                          _ -> leafEnd close
                     in node end : recordKeyword ++ (if leafText keyword == "enum" then [] else body source inner)
                  semicolon : _ -> node (treeEnd semicolon) : recordKeyword
                  [] -> []
          _ -> []
  _ -> []

-- | Without leading attributes and modifiers.
stripModifiers :: [Tree] -> [Tree]
stripModifiers (tree@(Atom leaf) : rest)
  | leafText leaf `elem` modifiers = stripModifiers rest
  | otherwise = tree : rest
stripModifiers (tree : rest)
  | isGroup "[" tree = stripModifiers rest
stripModifiers trees = trees

-- | Members: each ends at a semicolon, or at a brace group that is a body
-- rather than part of an initialiser or expression body.
splitMembers :: [Tree] -> [[Tree]]
splitMembers = filter (not . null) . go [] False
  where
    go acc _ [] = [reverse acc]
    go acc assigned (tree : rest)
      | isAtom ";" tree = reverse (tree : acc) : go [] False rest
      | isGroup "{" tree,
        not assigned =
          case rest of
            -- class C { } ; keeps its optional semicolon.
            semicolon : more | isAtom ";" semicolon -> reverse (semicolon : tree : acc) : go [] False more
            _ -> reverse (tree : acc) : go [] False rest
      | otherwise = go (tree : acc) (assigned || isAtom "=" tree || isAtom "=>" tree) rest
