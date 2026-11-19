-- | Swift declarations and imports for authoring advice. Recognised: class,
-- struct, enum, extension and actor declarations (the grammar's
-- class_declaration), protocol and typealias declarations, and function
-- declarations with a body (operator functions included) at any depth;
-- import declarations, whose module path is read as written. Protocol
-- requirements, initialisers, properties and subscripts declare nothing
-- here; #if directives are read as code (the grammar's directive is not an
-- unsupported construct), and Swift has no module names in the facts.
-- Limits: statements end at line breaks, so a typealias's type is read to
-- the last token that continues it on its line or inside its brackets and
-- angle brackets; a declaration a macro expands to is not seen.
-- ref:DEC-authoring-advisories
module LawSpec.Authoring.Languages.Swift (facts) where

import Data.Char (isAlpha, isAlphaNum, isDigit, isSpace)
import Data.Text (Text)
import qualified Data.Text as T
import LawSpec.Authoring.Syntax
import Text.Megaparsec
import Text.Megaparsec.Char (char, string)

facts :: Text -> Facts
facts source = case swiftLeaves source of
  Left problem -> unreadable problem
  Right leaves -> case brackets [("(", ")"), ("[", "]"), ("{", "}")] (filter (not . directive) leaves) of
    Left problem -> unreadable problem
    Right trees ->
      let misread = attributed trees
          leaves' = [if leafStart l `elem` misread then l {leafKind = Name, leafName = Just (leafText l)} else l | l <- leaves]
       in assemble source leaves' (scan source table False trees)
  where
    table = position source
    unreadable problem = failed ("Native syntax could not be read: " <> T.pack problem)
    directive leaf = leafKind leaf == Word && leafText leaf `elem` ["#if", "#else", "#elseif", "#endif"]

-- | The grammar reads @Attribute (T) throws -> U as an attribute with
-- arguments followed by a type named throws; that throws counts as a
-- name, as it did in the advice before.
attributed :: [Tree] -> [Int]
attributed trees = case trees of
  [] -> []
  Atom at : Atom _ : group : Atom throws : more
    | leafText at == "@" && nonEmpty group && leafText throws == "throws" ->
        leafStart throws : attributed (group : more)
  Group _ inner _ : more -> attributed inner ++ attributed more
  _ : more -> attributed more
  where
    nonEmpty (Group open (_ : _) _) = leafText open == "("
    nonEmpty _ = False

swiftLeaves :: Text -> Either String [Leaf]
swiftLeaves = lexSource (spaces [lineComment "//", blockComment True "/*" "*/"]) step
  where
    step previous =
      choice
        [ (: []) <$> try (plain rawString),
          try (literal "\"\"\""),
          literal "\"",
          (: []) <$> plain number,
          (: []) <$> try pound,
          (: []) <$> try (plain (string "@escaping" <|> string "@autoclosure") <* notFollowedBy (satisfy isAlphaNum)),
          (: []) <$> identifier previous,
          (: []) <$> symbol (try (string "as?" <|> string "as!" <|> string "try?" <|> string "try!")),
          (: []) <$> symbol (operatorFrom operators <|> (T.singleton <$> anySingle))
        ]
    -- #"..."# with any number of #s: one leaf.
    rawString = do
      hashes <- takeWhile1P Nothing (== '#')
      quotes <- string "\"\"\"" <|> string "\""
      let close = quotes <> hashes
      body <- T.pack <$> manyTill anySingle (lookAhead (string close))
      _ <- string close
      pure (hashes <> quotes <> body <> close)
    -- A string: its quotes, text, escapes and \( interpolations ), whose
    -- delimiters are not brackets of the source.
    literal quotes =
      delimited (string quotes) (string quotes) [interpolation, unicode, escape] (\c -> c == '\\' || c == '"')
    unicode = (: []) <$> plain (try (string "\\u{" <> takeWhileP Nothing (/= '}') <> string "}"))
    interpolation = do
      open <- plain (try (string "\\("))
      inner <- code (0 :: Int)
      pure (open : inner)
    code depth = do
      _ <- takeWhileP Nothing isSpace
      next <- lookAhead anySingle
      case next of
        ')' | depth == 0 -> (: []) <$> plain (string ")")
        _ -> do
          leaves <- step Nothing
          let change = sum [delta (leafText l) | l <- leaves, leafKind l == Symbol]
          (leaves ++) <$> code (depth + change)
    delta t
      | t `elem` ["(", "[", "{"] = 1
      | t `elem` [")", "]", "}"] = -1
      | otherwise = 0 :: Int
    pound = do
      start <- getOffset
      _ <- char '#'
      text <- takeWhile1P Nothing (\c -> isAlphaNum c || c == '_')
      end <- getOffset
      pure (Leaf Word ("#" <> text) Nothing start end)
    number = do
      first <- satisfy isDigit
      rest <-
        many
          ( try
              ( do
                  e <- satisfy (`elem` ("eEpP" :: String))
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
      text <-
        (string "`" <> takeWhileP Nothing (/= '`') <> string "`")
          <|> (T.cons <$> char '$' <*> takeWhileP Nothing (\c -> isAlphaNum c || c == '_'))
          <|> identifierWith (\c -> isAlpha c || c == '_') (\c -> isAlphaNum c || c == '_')
      end <- getOffset
      next <- lookAhead (takeWhileP Nothing (\c -> c == ' ' || c == '\t') *> optional anySingle)
      labelColon <- lookAhead (optional (try (takeWhileP Nothing isSpace *> char ':' *> notFollowedBy (char ':'))))
      let member = fmap leafText previous == Just "."
          -- An argument or parameter label is a name, whatever its
          -- spelling (random(in:), contains(where:)).
          labelled =
            labelColon /= Nothing
              && text `notElem` ["self", "super", "nil", "true", "false", "actor"]
              && (text /= "default" || fmap leafText previous `elem` map Just [",", "(", "["])
          accessor = text `elem` ["get", "set", "willSet", "didSet"]
          before c = isAlpha c || c == '@' || c == '{' || c == '\n' || c == '}'
          wildcard = text == "_" && (fmap leafText previous `elem` map Just ["for", "case"] || next == Just ')')
          keyword =
            text == "actor"
              || not member
                && not labelled
                && ( text `elem` reserved
                       || (text `elem` contextual && not accessor && maybe False (\c -> before c || c == '(') next)
                       || (accessor && (maybe False before next || (fmap leafText previous == Just "(" && next == Just ')')))
                       || wildcard
                   )
          -- The typealias keyword is a leaf whose type mentions an alias,
          -- so it counts among the identifiers.
          naming
            | text == "typealias" = Just text
            | keyword = Nothing
            | otherwise = Just text
      pure (Leaf (if keyword then Word else Name) text naming start end)
    operators = ["->", "...", "..<", "??", "===", "!==", "==", "!=", "<=", "&&", "||", "+=", "-=", "*=", "/=", "%="]

reserved :: [Text]
reserved =
  [ "associatedtype",
    "class",
    "deinit",
    "enum",
    "extension",
    "fileprivate",
    "func",
    "import",
    "init",
    "inout",
    "internal",
    "let",
    "operator",
    "private",
    "precedencegroup",
    "protocol",
    "public",
    "rethrows",
    "static",
    "struct",
    "subscript",
    "typealias",
    "var",
    "break",
    "case",
    "catch",
    "continue",
    "default",
    "do",
    "else",
    "fallthrough",
    "for",
    "guard",
    "if",
    "in",
    "repeat",
    "return",
    "throw",
    "switch",
    "where",
    "while",
    "as",
    "false",
    "is",
    "nil",
    "self",
    "super",
    "throws",
    "true",
    "try",
    "await",
    "async"
  ]

-- | Words that are keywords before a declaration or block and names
-- elsewhere (a member access is always a name).
contextual :: [Text]
contextual =
  ["open", "final", "override", "mutating", "nonmutating", "convenience", "required", "lazy", "weak", "unowned", "optional", "indirect", "dynamic", "nonisolated", "isolated", "prefix", "postfix", "infix", "package", "get", "set", "willSet", "didSet", "some", "any", "consuming", "borrowing", "distributed"]

modifiers :: [Text]
modifiers =
  ["public", "private", "fileprivate", "internal", "open", "package", "static", "class", "final", "override", "mutating", "nonmutating", "convenience", "required", "lazy", "weak", "unowned", "optional", "indirect", "dynamic", "nonisolated", "isolated", "prefix", "postfix", "infix", "distributed", "consuming", "borrowing"]

-- | Declarations and imports in a sequence and the groups in it. Inside a
-- protocol body a function is a requirement, not a declaration.
scan :: Text -> Position -> Bool -> [Tree] -> [Node]
scan source table protocol = go []
  where
    go _ [] = []
    go before trees@(tree : rest) = case trees of
      Atom keyword : Atom name' : more
        | leafText keyword `elem` ["struct", "class", "enum", "actor"],
          Just declared <- leafName name' ->
            typeDeclaration before keyword declared more False ++ continue
      Atom keyword : more
        | leafText keyword == "extension",
          (path, _) <- break (\t -> isAtom ":" t || isAtom "where" t || isGroup "{" t) more,
          not (null path) ->
            typeDeclaration before keyword (spanText source path) more False ++ continue
      Atom keyword : Atom name' : more
        | leafText keyword == "protocol",
          Just declared <- leafName name' ->
            typeDeclaration before keyword declared more True ++ continue
      Atom keyword : Atom name' : more
        | leafText keyword == "typealias",
          Just declared <- leafName name' ->
            let typed = typeAfter more
                end = maybe (leafEnd name') treeEnd (lastOf typed)
             in declaration (modifiersStart before (leafStart keyword)) end "typealias_declaration" declared True : continue
      Atom keyword : more
        | leafText keyword == "func",
          not protocol,
          Just declared <- functionName keyword,
          body : _ <- [t | t <- more, isGroup "{" t] ->
            declaration (modifiersStart before (leafStart keyword)) (treeEnd body) "function_declaration" declared False : continue
      Atom keyword : more
        | leafText keyword == "import" ->
            let kinds = takeWhile isKind more
                path = importPath (drop (length kinds) more)
                skipped = drop (length kinds + length path) more
             in [ Node (modifiersStart before (leafStart keyword)) (treeEnd (last path)) 0 (ImportFact (spanText source path))
                | not (null path)
                ]
                  ++ go (reverse (kinds ++ path) ++ tree : before) skipped
      _ -> continue
      where
        continue = nestedIn tree ++ go (tree : before) rest
    -- A protocol's body holds requirements; every other body declarations.
    typeDeclaration before keyword declared more isProtocol =
      case [t | t <- more, isGroup "{" t] of
        Group _ _ close : _ ->
          [ declaration
              (modifiersStart before (leafStart keyword))
              (leafEnd close)
              (if isProtocol then "protocol_declaration" else "class_declaration")
              declared
              (not isProtocol)
          ]
        _ -> []
    nestedIn (Group _ inner _) = scan source table False inner
    nestedIn _ = []
    isKind t = any (`isAtom` t) ["struct", "class", "enum", "protocol", "func", "var", "let", "typealias"]
    importPath (first@(Atom _) : more) = first : dotted more
    importPath _ = []
    dotted (dot : name' : more) | isAtom "." dot = dot : name' : dotted more
    dotted _ = []
    -- The operator or name after func, as written.
    functionName keyword =
      let after = T.dropWhile isSpace (T.drop (leafEnd keyword) source)
          named = T.takeWhile (\c -> isAlphaNum c || c == '_' || c == '`' || c == '$') after
          operator = T.takeWhile (`elem` ("/=-+!*%<>&|^~?." :: String)) after
       in if not (T.null named) then Just named else if T.null operator then Nothing else Just operator
    -- The start of the attributes and modifiers before a keyword.
    modifiersStart before start = case before of
      Atom l : more
        | leafText l `elem` modifiers -> modifiersStart more (leafStart l)
      group : Atom l : more
        | isGroup "(" group && leafText l `elem` modifiers -> modifiersStart more (leafStart l)
      Atom name' : Atom at : more
        | leafText at == "@" && leafKind name' `elem` [Name, Word] -> modifiersStart more (leafStart at)
      group : Atom name' : Atom at : more
        | isGroup "(" group && leafText at == "@" && leafKind name' `elem` [Name, Word] -> modifiersStart more (leafStart at)
      _ -> start
    lastOf [] = Nothing
    lastOf xs = Just (last xs)
    -- A type after "=": what continues it on its line, after a connector,
    -- or inside angle brackets.
    typeAfter more = case dropWhile (not . isAtom "=") more of
      equals : typed -> take (continued (treeEnd equals) (0 :: Int) typed) typed
      [] -> []
    continued _ _ [] = 0
    continued previousEnd depth (t : ts)
      | depth > 0 || sameLine previousEnd (treeStart t) || connector t =
          let depth' = depth + angle t
           in 1 + continued (treeEnd t) depth' ts
      | otherwise = 0
    angle t
      | isAtom "<" t = 1
      | isAtom ">" t = -1
      | otherwise = 0
    sameLine a b = lineAt table a == lineAt table b
    connector t = any (`isAtom` t) [".", "->", "&", ",", ">", "?", "!", "throws", "async"]

spanText :: Text -> [Tree] -> Text
spanText _ [] = ""
spanText source trees@(first : _) = slice source (treeStart first) (treeEnd (last trees))
