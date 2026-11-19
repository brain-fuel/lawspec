-- | Groovy declarations, imports and package names for authoring advice:
-- the class, interface, enum and method declarations of the Groovy grammar
-- (traits and records are not among the declarations the advice reads),
-- in class bodies, anonymous class bodies and at the top level of a
-- script. Members end at a semicolon, at a body, or at a line break that
-- does not continue the member; a method is a name and parameters after a
-- type, def or modifier. GStrings are split into their fragments and
-- interpolations; slashy and dollar-slashy strings are not recognised and
-- read as division. The extractor does not resolve names or types.
-- ref:DEC-authoring-advisories
module LawSpec.Authoring.Languages.Groovy (facts) where

import Data.Char (isAlpha, isAlphaNum)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import LawSpec.Authoring.Languages.Kotlin (interpolation)
import LawSpec.Authoring.Syntax
import Text.Megaparsec
import Text.Megaparsec.Char (char, string)

facts :: Text -> Facts
facts source = case groovyLeaves source of
  Left problem -> unreadable problem
  Right leaves -> case brackets [("(", ")"), ("[", "]"), ("{", "}")] leaves of
    Left problem -> unreadable problem
    Right trees -> assemble source leaves (body (position source) source True trees)
  where
    unreadable problem = failed ("Native syntax could not be read: " <> T.pack problem)

groovyLeaves :: Text -> Either String [Leaf]
groovyLeaves = lexSource space step
  where
    space = spaces [lineComment "//", blockComment False "/*" "*/", shebang]
    shebang = try (string "#!" *> takeWhileP Nothing (/= '\n') *> pure ())
    step _ =
      choice
        [ gstring "\"\"\"" (const False),
          gstring "\"" (== '\n'),
          (: []) <$> plain (singleQuoted "'''"),
          (: []) <$> plain (singleQuoted "'"),
          (: []) <$> plain numberLike,
          (: []) <$> identifier,
          (: []) <$> symbol (operatorFrom operators <|> (T.singleton <$> anySingle))
        ]
    gstring delimiter _ =
      delimited (string delimiter) (string delimiter) [escape, interpolation space step, dollar] (\c -> c == '"' || c == '$' || c == '\\')
    -- \$name and $name.property are one identifier leaf.
    dollar = do
      start <- getOffset
      sign <- char '$'
      first <- identifierWith (\c -> isAlpha c || c == '_') (\c -> isAlphaNum c || c == '_')
      rest <- many (try (T.cons <$> char '.' <*> identifierWith (\c -> isAlpha c || c == '_') (\c -> isAlphaNum c || c == '_')))
      end <- getOffset
      let text = T.cons sign (first <> T.concat rest)
      pure [Leaf Name text (Just text) start end]
    singleQuoted delimiter = do
      _ <- string delimiter
      content <- manyTill ((T.cons '\\' . T.singleton <$> (char '\\' *> anySingle)) <|> (T.singleton <$> anySingle)) (string delimiter)
      pure (delimiter <> T.concat content <> delimiter)
    identifier = do
      start <- getOffset
      text <- identifierWith (\c -> isAlpha c || c == '_' || c == '$') (\c -> isAlphaNum c || c == '_' || c == '$')
      end <- getOffset
      let keyword = text `elem` reserved
      pure (Leaf (if keyword then Word else Name) text (if keyword then Nothing else Just text) start end)
    operators = ["?.", "*.", "?:", "<=>", "..<", "..", "::", "->", "++", "--", "&&", "||", "===", "!==", "==~", "=~", "==", "!=", "<=", ">=", "+=", "-=", "*=", "/=", "%=", "**", "...", "@"]

-- | Words the Groovy grammar never reads as names. Primitive types, this
-- and super are names there.
reserved :: [Text]
reserved = ["abstract", "as", "assert", "break", "case", "catch", "class", "const", "continue", "def", "default", "do", "else", "enum", "extends", "false", "final", "finally", "for", "goto", "if", "implements", "import", "in", "instanceof", "interface", "native", "new", "null", "package", "private", "protected", "public", "return", "static", "strictfp", "switch", "synchronized", "throw", "throws", "trait", "transient", "true", "try", "volatile", "while"]

modifiers :: [Text]
modifiers = ["public", "private", "protected", "static", "final", "abstract", "synchronized", "native", "transient", "volatile", "strictfp", "default"]

-- | A class body, or the top level of a script: members and what they
-- hold.
body :: Position -> Text -> Bool -> [Tree] -> [Node]
body table source topLevel = concatMap member . members table
  where
    member trees@(first : rest)
      | isAtom "import" first =
          let path = qualified (dropWhile (isAtom "static") rest)
           in [Node (treeStart first) (treeEnd (lastOr first trees)) 0 (ImportFact (spanText source path)) | not (null path)]
      | isAtom "package" first =
          let path = qualified rest
           in [Node (treeStart first) (treeEnd (lastOr first trees)) 0 (ModuleFact (spanText source path)) | not (null path)]
      | Just _ <- typeKeyword trees = typeDeclaration table source trees
      | Atom r : Atom _ : components : rest' <- stripModifiers trees,
        leafText r == "record",
        isGroup "(" components =
          nestedIn table source components ++ concat [body table source False inner | Group open inner _ <- rest', leafText open == "{"]
      | Just node <- method trees = node : code table source trees
    member trees = code table source trees
    -- A qualified name: words joined by dots.
    qualified (n@(Atom _) : dot : more) | isAtom "." dot, not (startsStar more) = n : dot : qualified more
    qualified (n@(Atom l) : _) | leafKind l /= Symbol = [n]
    qualified _ = []
    startsStar (t : _) = isAtom "*" t
    startsStar [] = True
    method trees@(first : _) =
      let (before, after) = break (isGroup "(") (stripAnnotations trees)
          signature = stripModifiers before
       in case after of
            _ : rest
              | length signature >= 2 || any (isAtom "def") before && not (null signature),
                not (any (isAtom "=") before),
                not (any (\t -> isAtom "new" t || isAtom "return" t) before),
                not (any (\t -> isAtom "." t || isAtom "?." t) (take 1 (drop 1 (reverse before)))),
                Atom final <- lastOr first before,
                Just name' <- leafName final,
                hasBody rest || not topLevel ->
                  let end = case [t | t <- rest, isGroup "{" t] of
                        terminator : _ -> treeEnd terminator
                        [] -> treeEnd (lastOr first trees)
                   in Just (declaration (treeStart first) end "method_declaration" name' False)
            _ -> Nothing
    method [] = Nothing
    hasBody rest = any (isGroup "{") rest

lastOr :: a -> [a] -> a
lastOr fallback = maybe fallback id . listToMaybe . reverse

spanText :: Text -> [Tree] -> Text
spanText _ [] = ""
spanText source trees@(first : _) = slice source (treeStart first) (treeEnd (lastOr first trees))

-- | Class-body members: each ends at a semicolon, after a body, or at a
-- line break that does not continue it. Annotation lines join the member
-- they annotate, and a body on its own line joins its header.
members :: Position -> [Tree] -> [[Tree]]
members table = filter (not . null) . go []
  where
    go acc [] = [reverse acc]
    go acc (tree : rest)
      | isAtom ";" tree = reverse acc : go [] rest
      | isGroup "{" tree,
        not (any (isAtom "=") acc),
        not (null acc),
        not (continuesAfterBody rest) =
          reverse (tree : acc) : go [] rest
      | otherwise = case rest of
          next : _
            | lineAt table (treeEnd tree) < lineAt table (treeStart next),
              not (continues (tree : acc) next) ->
                reverse (tree : acc) : go [] rest
          _ -> go (tree : acc) rest
    -- An enum constant's body is followed by a comma.
    continuesAfterBody (next : _) = isAtom "," next
    continuesAfterBody [] = False
    continues acc next =
      isGroup "{" next && not (any (isAtom "=") acc)
        || annotationOnly (reverse acc)
        || any (`isAtom` next) [".", "?.", "*.", "?:", "&&", "||", "+", "-", "*", "/", ":", "?", "extends", "implements", "throws", "==", "!=", "as", "instanceof"]
        || case acc of
          previous : _ -> any (`isAtom` previous) ["=", ",", ".", "?.", "+", "-", "*", "/", "&&", "||", "?", ":", "?:", "->", "extends", "implements", "throws", "new", "return", "==", "!=", "<", ">", "<=", ">=", "in", "@"] || isModifier previous
          [] -> False
    annotationOnly trees = not (null trees) && null (stripAnnotations trees)
    isModifier (Atom leaf) = leafText leaf `elem` modifiers && leafText leaf /= "def"
    isModifier _ = False

-- | Without leading annotations.
stripAnnotations :: [Tree] -> [Tree]
stripAnnotations (Atom leaf : rest)
  | leafText leaf == "@",
    not (any (isAtom "interface") (take 1 rest)) =
      annotation rest
  where
    annotation (Atom _ : Atom dot : more) | leafText dot == "." = annotation more
    annotation (Atom _ : arguments : more) | isGroup "(" arguments = stripAnnotations more
    annotation (Atom _ : more) = stripAnnotations more
    annotation more = more
stripAnnotations trees = trees

-- | Without leading annotations and modifiers.
stripModifiers :: [Tree] -> [Tree]
stripModifiers trees = case stripAnnotations trees of
  Atom leaf : rest | leafText leaf `elem` modifiers -> stripModifiers rest
  rest -> rest

-- | When a sequence starts a class, interface or enum declaration, its
-- keyword.
typeKeyword :: [Tree] -> Maybe Text
typeKeyword trees = case stripModifiers trees of
  Atom keyword : Atom name' : _
    | leafText keyword `elem` ["class", "interface", "enum"],
      Just _ <- leafName name' ->
        Just (leafText keyword)
  _ -> Nothing

-- | A class, interface or enum declaration and what it holds.
typeDeclaration :: Position -> Text -> [Tree] -> [Node]
typeDeclaration _ _ [] = []
typeDeclaration table source trees@(first : _) = case stripModifiers trees of
  Atom keyword : Atom name' : afterName ->
    let (header, rest) = break (isGroup "{") afterName
        kind = case leafText keyword of
          "class" -> "class_declaration"
          "interface" -> "interface_declaration"
          _ -> "enum_declaration"
     in case rest of
          braces@(Group _ inner _) : remaining ->
            declaration (treeStart first) (treeEnd braces) kind (maybe "" id (leafName name')) True
              : concatMap (nestedIn table source) header
              ++ (if leafText keyword == "enum" then enumBody table source inner else body table source False inner)
              ++ code table source remaining
          _ -> concatMap (nestedIn table source) afterName
  _ -> []

-- | An enum body: constants up to the first top-level semicolon (or the
-- line after the last constant), then members.
enumBody :: Position -> Text -> [Tree] -> [Node]
enumBody table source inner =
  let (constants, rest) = break (isAtom ";") inner
   in if null rest
        then concatMap (nestedIn table source) inner
        else concatMap (nestedIn table source) constants ++ body table source False (drop 1 rest)

nestedIn :: Position -> Text -> Tree -> [Node]
nestedIn table source (Group open inner _) = codeWith (leafText open /= "(") table source inner
nestedIn _ _ _ = []

-- | Code: local type declarations, anonymous class bodies, and whatever
-- groups hold.
code :: Position -> Text -> [Tree] -> [Node]
code = codeWith True

-- | Code, where the first tree starts a statement unless it opens a
-- parenthesised list (where var names a resource the way any name does).
codeWith :: Bool -> Position -> Text -> [Tree] -> [Node]
codeWith statementStart table source = go Nothing
  where
    go _ [] = []
    go previous (tree@(Atom leaf) : rest)
      | leafText leaf == "var",
        maybe statementStart (\p -> isAtom ";" p || lineAt table (treeEnd p) < lineAt table (leafStart leaf)) previous =
          Node (leafStart leaf) (leafEnd leaf) 0 KeywordFact : go (Just tree) rest
    go previous trees@(tree : rest)
      | maybe True (not . isAtom ".") previous,
        Just _ <- typeKeyword trees =
          let (declarationTrees, remaining) = throughBody trees
           in typeDeclaration table source declarationTrees ++ go Nothing remaining
      | isAtom "new" tree = anonymous rest
      | otherwise = nestedIn table source tree ++ go (Just tree) rest
    throughBody trees =
      let (header, rest) = break (isGroup "{") trees
       in case rest of
            braces : remaining -> (header ++ [braces], remaining)
            [] -> (header, [])
    anonymous rest =
      let (creation, after) = break (\t -> isGroup "(" t || isGroup "{" t || isAtom ";" t) rest
       in case after of
            arguments : Group brace inner _ : remaining
              | isGroup "(" arguments,
                leafText brace == "{" ->
                  concatMap (nestedIn table source) creation ++ nestedIn table source arguments ++ body table source False inner ++ go Nothing remaining
            _ -> concatMap (nestedIn table source) creation ++ go Nothing after
