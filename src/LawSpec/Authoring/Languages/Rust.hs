-- | Rust declarations, imports and unsupported macros for authoring advice.
-- Recognised: struct, enum, type alias (with @=@) and function items with a
-- body, at any depth (modules, impl and trait blocks, function bodies);
-- @use@ declarations, whose argument is read as written; macro
-- invocations and @macro_rules!@ definitions, which are unsupported
-- constructs (an @unimplemented!@, @todo!@ or @panic!@ holding only string
-- literals excepted). Macro and attribute token trees are not read for
-- declarations, as the Rust grammar does not parse them. Rust has no module
-- names in the facts (a @mod@ item is not a module declaration here).
-- Limits: a declaration produced by a macro is not seen; a @fn@ is
-- recognised by its keyword and name, so a body that is not a brace group
-- before the first semicolon is read as a signature.
-- ref:DEC-authoring-advisories
module LawSpec.Authoring.Languages.Rust (facts) where

import Data.Char (isAlpha, isAlphaNum, isDigit)
import Data.Text (Text)
import qualified Data.Text as T
import LawSpec.Authoring.Syntax
import Text.Megaparsec
import Text.Megaparsec.Char (char, string)

facts :: Text -> Facts
facts source = case rustLeaves source of
  Left problem -> unreadable problem
  Right leaves -> case brackets [("(", ")"), ("[", "]"), ("{", "}")] leaves of
    Left problem -> unreadable problem
    Right trees -> assemble source (tokenTrees (ranges trees) leaves) (items source table trees)
  where
    table = position source
    unreadable problem = failed ("Native syntax could not be read: " <> T.pack problem)

rustLeaves :: Text -> Either String [Leaf]
rustLeaves = lexSource (spaces [lineComment "//", blockComment True "/*" "*/"]) step
  where
    step previous =
      choice
        [ (: []) <$> try rawString,
          (: []) <$> plain (try byteCharacter),
          try (delimited (string "b\"" <|> string "c\"") (string "\"") [escape] stop),
          delimited (string "\"") (string "\"") [escape] stop,
          try characterOrLifetime,
          (: []) <$> plain (number previous),
          (: []) <$> try (symbol (string "macro_rules!")),
          (: []) <$> try metavariable,
          (: []) <$> identifier previous,
          (: []) <$> symbol (operatorFrom operators <|> (T.singleton <$> anySingle))
        ]
    stop c = c == '\\' || c == '"'
    -- A raw string is one leaf: its body, without the delimiters.
    rawString = do
      _ <- optional (char 'b' <|> char 'c')
      _ <- char 'r'
      hashes <- takeWhileP Nothing (== '#')
      _ <- char '"'
      start <- getOffset
      let close = "\"" <> hashes
      body <- T.pack <$> manyTill anySingle (lookAhead (string close))
      end <- getOffset
      _ <- string close
      pure (Leaf Literal body Nothing start end)
    byteCharacter = do
      _ <- char 'b'
      body <- characterBody
      pure ("b" <> body)
    characterBody = do
      _ <- char '\''
      first <- (T.cons '\\' . T.singleton <$> (char '\\' *> anySingle)) <|> (T.singleton <$> anySingle)
      rest <- takeWhileP Nothing (/= '\'')
      _ <- char '\''
      pure ("'" <> first <> rest <> "'")
    -- 'a' is a character; 'a without a closing quote is a lifetime, a
    -- quote leaf and then its name.
    characterOrLifetime =
      ((: []) <$> plain (try characterLiteral))
        <|> ((: []) <$> symbol (string "'"))
    characterLiteral = do
      _ <- char '\''
      first <- (T.cons '\\' . T.singleton <$> (char '\\' *> anySingle)) <|> (T.singleton <$> anySingle)
      rest <-
        if T.take 1 first == "\\"
          then takeWhileP Nothing (/= '\'')
          else pure ""
      _ <- char '\''
      pure ("'" <> first <> rest <> "'")
    -- After a dot, a number is a tuple index without a fraction.
    number previous = do
      first <- satisfy isDigit
      let afterDot = fmap leafText previous == Just "."
      rest <- many (if afterDot then digitsOnly else part)
      pure (T.concat (T.singleton first : rest))
    digitsOnly = T.singleton <$> satisfy (\c -> isDigit c || c == '_')
    part =
      try
        ( do
            e <- satisfy (`elem` ("eE" :: String))
            sign <- satisfy (`elem` ("+-" :: String))
            digit <- satisfy isDigit
            pure (T.pack [e, sign, digit])
        )
        <|> try (T.cons <$> char '.' <*> (T.singleton <$> satisfy isDigit))
        <|> (T.singleton <$> satisfy (\c -> isAlphaNum c || c == '_'))
    metavariable = do
      start <- getOffset
      _ <- char '$'
      text <- identifierWith (\c -> isAlpha c || c == '_') (\c -> isAlphaNum c || c == '_')
      end <- getOffset
      pure (Leaf Name ("$" <> text) (Just ("$" <> text)) start end)
    identifier previous = do
      start <- getOffset
      raw <- optional (try (string "r#" <* lookAhead (satisfy (\c -> isAlpha c || c == '_'))))
      text <- identifierWith (\c -> isAlpha c || c == '_') (\c -> isAlphaNum c || c == '_')
      end <- getOffset
      next <- lookAhead (optional (string "::"))
      closing <- lookAhead (optional (try (takeWhileP Nothing (`elem` (" \t\n" :: String)) *> char '>')))
      let full = maybe "" id raw <> text
          lifetime = fmap (\l -> leafKind l == Symbol && leafText l == "'") previous == Just True
          -- An inferred type argument (Vec<_>) is a type, not a pattern.
          inferred = text == "_" && (fmap leafText previous == Just "<" || closing /= Nothing)
          keyword = not lifetime && not inferred && raw == Nothing && (text `elem` reserved || (text `elem` primitives && next == Nothing))
      pure (Leaf (if keyword then Word else Name) full (if keyword then Nothing else Just full) start end)
    operators = ["::", "->", "=>", "==", "!=", "<=", "&&", "||", "+=", "-=", "*=", "/=", "%=", "^=", "&=", "|=", "<<=", ">>=", "<<", "..=", "...", ".."]

-- | Macro arguments, attribute arguments and macro_rules! bodies are token
-- trees, where the grammar reads words by a list of its own: these are
-- keywords there, every other word a name; a macro_rules! fragment
-- specifier ($x:ty) is a keyword.
tokenTrees :: [(Int, Int)] -> [Leaf] -> [Leaf]
tokenTrees spans = go Nothing Nothing
  where
    go _ _ [] = []
    go before twoBefore (leaf : rest) =
      let inside = any (\(start, end) -> leafStart leaf >= start && leafEnd leaf <= end) spans
          lifetime = fmap leafText before == Just "'"
          fragment = fmap leafText before == Just ":" && fmap (T.isPrefixOf "$" . leafText) twoBefore == Just True
          leaf'
            | not inside || lifetime || leafKind leaf `notElem` [Name, Word] = leaf
            | T.isPrefixOf "$" (leafText leaf) = leaf
            | fragment || leafText leaf `elem` tokenKeywords || leafText leaf `elem` primitives = leaf {leafKind = Word, leafName = Nothing}
            | otherwise = leaf {leafKind = Name, leafName = Just (leafText leaf)}
       in leaf' : go (Just leaf) before rest
    tokenKeywords =
      ["as", "async", "await", "break", "const", "continue", "default", "enum", "fn", "for", "if", "impl", "let", "loop", "match", "mod", "pub", "return", "static", "struct", "trait", "type", "union", "unsafe", "use", "where", "while", "self", "super", "crate", "true", "false", "mut", "_"]

-- | The spans of the token trees in a source.
ranges :: [Tree] -> [(Int, Int)]
ranges = go
  where
    go trees = case trees of
      [] -> []
      Atom hash : group : more
        | leafText hash == "#" && isGroup "[" group -> span' group ++ go more
      Atom hash : Atom bang : group : more
        | leafText hash == "#" && leafText bang == "!" && isGroup "[" group -> span' group ++ go more
      Atom rules : more
        | leafText rules == "macro_rules!" ->
            case dropWhile (\t -> not (isGroup "{" t || isGroup "(" t || isGroup "[" t)) more of
              body : more' -> span' body ++ go more'
              [] -> []
      Atom macro : Atom bang : group@(Group _ _ _) : more
        | leafText bang == "!" && leafKind macro == Name -> span' group ++ go more
      Group _ inner _ : more -> go inner ++ go more
      _ : more -> go more
    span' tree = [(treeStart tree, treeEnd tree)]

reserved :: [Text]
reserved =
  [ "as",
    "async",
    "await",
    "break",
    "const",
    "continue",
    "crate",
    "dyn",
    "else",
    "enum",
    "extern",
    "false",
    "fn",
    "for",
    "if",
    "impl",
    "in",
    "let",
    "loop",
    "match",
    "mod",
    "move",
    "mut",
    "pub",
    "ref",
    "return",
    "self",
    "static",
    "struct",
    "super",
    "trait",
    "true",
    "type",
    "unsafe",
    "use",
    "where",
    "while",
    "_"
  ]

-- | Primitive types are not names, except as the head of a path (i32::MAX).
primitives :: [Text]
primitives = ["i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128", "usize", "f32", "f64", "bool", "char", "str"]

-- | Items, use declarations and macros in a sequence and the groups in it.
items :: Text -> Position -> [Tree] -> [Node]
items source table = go []
  where
    go _ [] = []
    go before trees@(tree : rest) = case trees of
      -- #[...] and #![...]: attribute token trees.
      Atom hash : group : more
        | leafText hash == "#",
          isGroup "[" group ->
            go (group : tree : before) more
      Atom hash : Atom bang : group : more
        | leafText hash == "#",
          leafText bang == "!",
          isGroup "[" group ->
            go (group : Atom bang : tree : before) more
      Atom rules : _ | leafText rules == "macro_rules!" -> macroDefinition before trees
      Atom macro : Atom bang : group@(Group _ _ _) : more
        | leafText bang == "!",
          leafKind macro == Name ->
            let start = macroStart before (leafStart macro)
                limit =
                  [ Node start (treeEnd group) 0 (LimitFact ("Unsupported macro_invocation at line " <> T.pack (show (lineAt table start))))
                  | not (exempt (leafText macro) (pathOf before) group)
                  ]
             in limit ++ go (group : Atom bang : tree : before) more
      Atom keyword : Atom name' : more
        | leafText keyword `elem` ["fn", "struct", "enum", "type"],
          Just declared <- leafName name' ->
            item keyword declared before more ++ nestedGo tree rest before
      Atom keyword : more
        | leafText keyword == "use" ->
            let (argument, after) = break (isAtom ";") more
             in case after of
                  semicolon : _
                    | not (null argument) ->
                        Node (modifiersStart before (leafStart keyword)) (treeEnd semicolon) 0 (ImportFact (spanText source argument))
                          : go (tree : before) rest
                  _ -> go (tree : before) rest
      _ -> nestedGo tree rest before
    nestedGo tree rest before = nestedIn tree ++ go (tree : before) rest
    nestedIn (Group _ inner _) = go [] inner
    nestedIn _ = []
    macroDefinition before trees =
      let (definition, after) = breakAfterBody trees
          start = case trees of
            first : _ -> treeStart first
            [] -> 0
          end = case reverse definition of
            final : _ -> treeEnd final
            [] -> start
       in Node start end 0 (LimitFact ("Unsupported macro_definition at line " <> T.pack (show (lineAt table start))))
            : go (reverse definition ++ before) after
    -- macro_rules! name { ... } or ( ... );
    breakAfterBody trees =
      let (header, rest) = break isBody trees
       in case rest of
            body : more -> case more of
              semicolon : more' | isAtom ";" semicolon && not (isGroup "{" body) -> (header ++ [body, semicolon], more')
              _ -> (header ++ [body], more)
            [] -> (header, [])
    isBody t = isGroup "{" t || isGroup "(" t || isGroup "[" t
    -- An item from its modifiers to its body or semicolon.
    item keyword declared before more =
      let kind = case leafText keyword of
            "fn" -> "function_item"
            "struct" -> "struct_item"
            "enum" -> "enum_item"
            _ -> "type_item"
          start = modifiersStart before (leafStart keyword)
          terminator = [t | t <- more, isGroup "{" t || isAtom ";" t]
          (header, _) = break (isAtom ";") more
       in case (leafText keyword, terminator) of
            ("fn", t : _) | isGroup "{" t -> [declaration start (treeEnd t) kind declared False]
            ("type", t : _) | isAtom ";" t, any (isAtom "=") header -> [declaration start (treeEnd t) kind declared True]
            ("struct", t : _) -> [declaration start (treeEnd t) kind declared True]
            ("enum", t : _) | isGroup "{" t -> [declaration start (treeEnd t) kind declared True]
            _ -> []
    -- The start of the visibility and function modifiers before a keyword.
    modifiersStart before start = case before of
      Atom l : more
        | leafText l `elem` ["pub", "const", "async", "unsafe", "default"] -> modifiersStart more (leafStart l)
        | leafText l == "\"" -> case dropWhile (\t -> not (isAtom "\"" t)) more of
            Atom open : Atom extern : more' | leafText open == "\"" && leafText extern == "extern" -> modifiersStart more' (leafStart extern)
            _ -> start
        | leafText l == "extern" -> modifiersStart more (leafStart l)
      group : Atom l : more
        | isGroup "(" group && leafText l == "pub" -> modifiersStart more (leafStart l)
      _ -> start
    -- A macro path's first leaf (std::panic!).
    macroStart (Atom colons : Atom segment : more) _
      | leafText colons == "::" = macroStart more (leafStart segment)
    macroStart _ start = start
    pathOf before = case before of
      Atom colons : _ | leafText colons == "::" -> True
      _ -> False
    exempt name' qualified (Group _ inner _) =
      not qualified
        && name' `elem` ["unimplemented", "todo", "panic"]
        && stringsOnly (concatMap treeLeaves inner)
    exempt _ _ _ = False
    stringsOnly [] = True
    stringsOnly (leaf : rest)
      | leafText leaf == "," && leafKind leaf == Symbol = stringsOnly rest
      | leafKind leaf == Symbol && leafText leaf `elem` ["\"", "b\"", "c\""] =
          case break (\l -> leafKind l == Symbol && leafText l == "\"") rest of
            (_, _ : more) -> stringsOnly more
            _ -> False
      | otherwise = False

spanText :: Text -> [Tree] -> Text
spanText _ [] = ""
spanText source trees@(first : _) = slice source (treeStart first) (treeEnd (last trees))
