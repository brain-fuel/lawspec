-- | Java declarations, imports and package names for authoring advice: the
-- class, record, interface, enum and method declarations of the Java
-- grammar at any depth (members, local and anonymous classes).
-- ref:DEC-authoring-advisories
module LawSpec.Authoring.Languages.Java (facts) where

import Data.Char (isAlpha, isAlphaNum)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import LawSpec.Authoring.Syntax
import Text.Megaparsec
import Text.Megaparsec.Char (char, string)

facts :: Text -> Facts
facts source = case javaLeaves source of
  Left problem -> unreadable problem
  Right leaves -> case brackets [("(", ")"), ("[", "]"), ("{", "}")] leaves of
    Left problem -> unreadable problem
    Right trees -> assemble source leaves (body source trees)
  where
    unreadable problem = failed ("Native syntax could not be read: " <> T.pack problem)

javaLeaves :: Text -> Either String [Leaf]
javaLeaves = lexSource (spaces [lineComment "//", blockComment False "/*" "*/"]) step
  where
    step previous =
      choice
        [ delimited (string "\"\"\"") (string "\"\"\"") [escape] (\c -> c == '\\' || c == '"'),
          delimited (string "\"") (string "\"") [escape] (\c -> c == '\\' || c == '"'),
          (: []) <$> plain characterLiteral,
          (: []) <$> plain numberLike,
          (: []) <$> identifier previous,
          (: []) <$> symbol (string "@interface"),
          (: []) <$> symbol (operatorFrom operators <|> (T.singleton <$> anySingle))
        ]
    identifier previous = do
      start <- getOffset
      text <- identifierWith (\c -> isAlpha c || c == '_' || c == '$') (\c -> isAlphaNum c || c == '_' || c == '$')
      end <- getOffset
      -- A member access names a method, whatever its spelling (Thread.yield).
      let keyword = text `elem` reserved && not (text == "yield" && fmap leafText previous == Just ".")
      pure (Leaf (if keyword then Word else Name) text (if keyword then Nothing else Just text) start end)
    characterLiteral = do
      _ <- char '\''
      first <- (T.cons '\\' . T.singleton <$> (char '\\' *> anySingle)) <|> (T.singleton <$> anySingle)
      rest <- takeWhileP Nothing (/= '\'')
      _ <- char '\''
      pure ("'" <> first <> rest <> "'")
    operators = ["::", "->", "++", "--", "&&", "||", "==", "!=", "<=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<", "...", "<<=", ">>="]

reserved :: [Text]
reserved =
  [ "abstract",
    "assert",
    "boolean",
    "break",
    "byte",
    "case",
    "catch",
    "char",
    "class",
    "const",
    "continue",
    "default",
    "do",
    "double",
    "else",
    "enum",
    "extends",
    "final",
    "finally",
    "float",
    "for",
    "goto",
    "if",
    "implements",
    "import",
    "instanceof",
    "int",
    "interface",
    "long",
    "native",
    "new",
    "package",
    "private",
    "protected",
    "public",
    "return",
    "short",
    "static",
    "strictfp",
    "super",
    "switch",
    "synchronized",
    "this",
    "throw",
    "throws",
    "transient",
    "try",
    "void",
    "volatile",
    "while",
    "true",
    "false",
    "null",
    "sealed",
    "permits",
    "yield"
  ]

modifiers :: [Text]
modifiers = ["public", "private", "protected", "static", "final", "abstract", "sealed", "non-sealed", "strictfp", "default", "synchronized", "native", "transient", "volatile"]

-- | A class body, or the top level: imports, the package, and members.
body :: Text -> [Tree] -> [Node]
body source = concatMap member . splitMembers
  where
    member trees@(first : rest)
      | isAtom "import" first =
          let path = takeWhile (not . isAtom "*") (dropWhile (isAtom "static") rest)
              path' = reverse (dropWhile (\t -> isAtom "." t || isAtom ";" t) (reverse path))
           in [Node (treeStart first) (treeEnd (last trees)) 0 (ImportFact (spanText source path')) | not (null path')]
      | isAtom "package" first =
          let path = filter (not . isAtom ";") rest
           in [Node (treeStart first) (treeEnd (last trees)) 0 (ModuleFact (spanText source path)) | not (null path)]
      | Just _ <- typeKeyword trees = fst (typeDeclaration source trees) ++ code source (snd (typeDeclaration source trees))
      | Just node <- method trees = node : code source trees
    member trees = code source trees
    method trees@(first : _) =
      let (before, after) = break (isGroup "(") (stripModifiers trees)
       in case after of
            _ : rest
              | not (null before),
                not (any (isAtom "=") before),
                length (dropTypeParameters before) >= 2,
                Atom final <- last before,
                Just name' <- leafName final ->
                  let end = case [t | t <- rest, isGroup "{" t || isAtom ";" t] of
                        terminator : _ -> treeEnd terminator
                        [] -> treeEnd (last trees)
                   in Just (declaration (treeStart first) end "method_declaration" name' False)
            _ -> Nothing
    method [] = Nothing

spanText :: Text -> [Tree] -> Text
spanText _ [] = ""
spanText source trees@(first : _) = slice source (treeStart first) (treeEnd (last trees))

-- | When a sequence starts a type declaration (after its modifiers and
-- annotations), its keyword.
typeKeyword :: [Tree] -> Maybe Text
typeKeyword trees = case stripModifiers trees of
  Atom keyword : Atom name' : _
    | leafText keyword `elem` ["class", "interface", "enum"],
      Just _ <- leafName name' ->
        Just (leafText keyword)
  Atom keyword : Atom name' : next : _
    | leafText keyword == "record",
      Just _ <- leafName name',
      isGroup "(" next || isAtom "<" next ->
        Just "record"
  _ -> Nothing

-- | A type declaration from its first modifier to its body, and what
-- follows it.
typeDeclaration :: Text -> [Tree] -> ([Node], [Tree])
typeDeclaration _ [] = ([], [])
typeDeclaration source trees@(first : _) = case stripModifiers trees of
  Atom keyword : Atom name' : afterName ->
    let (header, rest) = break (isGroup "{") afterName
        kind = case leafText keyword of
          "class" -> "class_declaration"
          "interface" -> "interface_declaration"
          "enum" -> "enum_declaration"
          _ -> "record_declaration"
        contextual = [Node (leafStart keyword) (leafEnd keyword) 0 KeywordFact | leafText keyword == "record"] ++ [Node (treeStart t) (treeEnd t) 0 KeywordFact | t <- header, isAtom "permits" t]
     in case rest of
          braces@(Group _ inner _) : remaining ->
            ( declaration (treeStart first) (treeEnd braces) kind (fromMaybe "" (leafName name')) True
                : contextual
                ++ concatMap (nestedIn source) header
                ++ (if leafText keyword == "enum" then enumBody source inner else body source inner),
              remaining
            )
          [] -> (concatMap (nestedIn source) header, [])
          _ -> ([], rest)
  _ -> ([], trees)

-- | Trees without leading modifiers and annotations (other than
-- @interface, which declares an annotation type).
stripModifiers :: [Tree] -> [Tree]
stripModifiers (Atom leaf : rest)
  | leafText leaf `elem` modifiers = stripModifiers rest
  | leafText leaf == "@" = annotation rest
  where
    annotation (Atom _ : Atom dot : more) | leafText dot == "." = annotation more
    annotation (Atom _ : arguments : more) | isGroup "(" arguments = stripModifiers more
    annotation (Atom _ : more) = stripModifiers more
    annotation more = more
stripModifiers trees = trees

-- | Without a leading type parameter list.
dropTypeParameters :: [Tree] -> [Tree]
dropTypeParameters (Atom leaf : rest) | leafText leaf == "<" = closing (1 :: Int) rest
  where
    closing 0 trees = trees
    closing _ [] = []
    closing depth (Atom l : more)
      | leafText l == "<" = closing (depth + 1) more
      | leafText l == ">" = closing (depth - 1) more
    closing depth (_ : more) = closing depth more
dropTypeParameters trees = trees

-- | Class-body members: each ends at a semicolon, or at a brace group
-- that is a body rather than an initialiser.
splitMembers :: [Tree] -> [[Tree]]
splitMembers = filter (not . null) . go [] False
  where
    go acc _ [] = [reverse acc]
    go acc assigned (tree : rest)
      | isAtom ";" tree = reverse (tree : acc) : go [] False rest
      | isGroup "{" tree,
        not assigned =
          reverse (tree : acc) : go [] False rest
      | otherwise = go (tree : acc) (assigned || isAtom "=" tree) rest

-- | An enum body: constants (with optional bodies) up to the first
-- top-level semicolon, then members.
enumBody :: Text -> [Tree] -> [Node]
enumBody source inner =
  let (constants, rest) = break (isAtom ";") inner
   in concatMap constant (statements (isAtom ",") constants) ++ body source (drop 1 rest)
  where
    constant trees = concat [if isGroup "{" t then body source (inside t) else nestedIn source t | t <- trees]
    inside (Group _ inner' _) = inner'
    inside _ = []

nestedIn :: Text -> Tree -> [Node]
nestedIn source (Group _ inner _) = code source inner
nestedIn _ _ = []

-- | Code: local type declarations, anonymous class bodies, and whatever
-- groups hold.
code :: Text -> [Tree] -> [Node]
code source = go Nothing
  where
    go _ [] = []
    go previous trees@(tree : rest)
      | maybe True (not . isAtom ".") previous,
        Just _ <- typeKeyword trees =
          let (nodes, remaining) = typeDeclaration source trees
           in nodes ++ go Nothing remaining
      | isAtom "new" tree = anonymous rest
      | otherwise = nestedIn source tree ++ go (Just tree) rest
    anonymous rest =
      let (creation, after) = break (\t -> isGroup "(" t || isGroup "{" t || isAtom ";" t) rest
       in case after of
            arguments : Group brace inner _ : remaining
              | isGroup "(" arguments,
                leafText brace == "{" ->
                  concatMap (nestedIn source) creation ++ nestedIn source arguments ++ body source inner ++ go Nothing remaining
            _ -> concatMap (nestedIn source) creation ++ go Nothing after
