-- | Kotlin declarations and imports for authoring advice: the class
-- (including interface and enum class), object, function and type alias
-- declarations of the Kotlin grammar at any depth, and import headers.
-- Companion objects, object expressions and anonymous functions are not
-- declarations. Kotlin's package header is not a module fact (the advice
-- never read it). Declarations are found by their keywords after any
-- modifiers and annotations; an expression body or a header without a
-- body ends at the end of its logical line, by Kotlin's continuation
-- rules as far as tokens show them. The extractor does not resolve names
-- or types.
-- ref:DEC-authoring-advisories
module LawSpec.Authoring.Languages.Kotlin
  ( facts,
    interpolation,
  )
where

import Data.Char (isAlpha, isAlphaNum)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import LawSpec.Authoring.Syntax
import Text.Megaparsec
import Text.Megaparsec.Char (char, string)

facts :: Text -> Facts
facts source = case kotlinLeaves source of
  Left problem -> unreadable problem
  Right leaves -> case brackets [("(", ")"), ("[", "]"), ("{", "}")] leaves of
    Left problem -> unreadable problem
    Right trees -> assemble source leaves (scan (position source) source trees)
  where
    unreadable problem = failed ("Native syntax could not be read: " <> T.pack problem)

kotlinLeaves :: Text -> Either String [Leaf]
kotlinLeaves = lexSource space step
  where
    space = spaces [lineComment "//", blockComment True "/*" "*/"]
    step previous =
      choice
        [ stringLiteral "\"\"\"" (const False),
          stringLiteral "\"" (== '\\'),
          (: []) <$> plain characterLiteral,
          (: []) <$> plain numberLike,
          (: []) <$> identifier previous,
          (: []) <$> name (char '`' *> takeWhile1P Nothing (/= '`') <* char '`'),
          (: []) <$> symbol (operatorFrom operators <|> (T.singleton <$> anySingle))
        ]
    stringLiteral delimiter escapes =
      delimited
        (string delimiter)
        (string delimiter)
        ([escape | escapes '\\'] ++ [interpolation space step, template])
        (\c -> c == '"' || c == '$' || escapes c)
    template = do
      dollar <- plain (string "$")
      named <- name (identifierWith (\c -> isAlpha c || c == '_') (\c -> isAlphaNum c || c == '_'))
      pure [dollar, named]
    identifier previous = do
      start <- getOffset
      text <- identifierWith (\c -> isAlpha c || c == '_') (\c -> isAlphaNum c || c == '_')
      end <- getOffset
      let keyword = text `elem` never || text `elem` hard && not (fmap leafText previous `elem` [Just ".", Just "?."] && text `notElem` ["class", "this", "super"])
      pure (Leaf (if keyword then Word else Name) text (if keyword then Nothing else Just text) start end)
    characterLiteral = do
      _ <- char '\''
      first <- (T.cons '\\' <$> (char '\\' *> takeWhile1P Nothing (/= '\''))) <|> (T.singleton <$> anySingle)
      _ <- char '\''
      pure ("'" <> first <> "'")
    operators = ["::", "->", "?.", "?:", "!!", "++", "--", "&&", "||", "===", "!==", "==", "!=", "<=", ">=", "+=", "-=", "*=", "/=", "%=", "..<", "..", "@"]

-- | A string template's interpolated expression: its code, lexed as the
-- language's own, to the brace that closes it. The closing brace is a
-- literal leaf, so bracket grouping does not see it.
interpolation :: Lexer () -> (Maybe Leaf -> Lexer [Leaf]) -> Lexer [Leaf]
interpolation space step = do
  open <- plain (string "${")
  inner <- go (0 :: Int) Nothing []
  pure (open : inner)
  where
    go depth previous acc = do
      space
      closing <- optional (lookAhead (char '}'))
      case closing of
        Just _
          | depth == 0 -> do
              final <- plain (string "}")
              pure (reverse (final : acc))
        _ -> do
          leaves <- step previous
          let depth' = depth + length [() | l <- leaves, leafKind l == Symbol, leafText l == "{"] - length [() | l <- leaves, leafKind l == Symbol, leafText l == "}"]
          case reverse leaves of
            lastLeaf : _ -> go depth' (Just lastLeaf) (reverse leaves ++ acc)
            [] -> fail "empty token"

-- | Hard keywords: never names, except after a member access. The
-- keywords constructor and typealias are not among them: the advice reads
-- a leaf whose grammar type mentions constructor or alias as a name.
hard :: [Text]
hard = ["as", "break", "class", "continue", "do", "else", "false", "for", "fun", "if", "in", "interface", "is", "null", "object", "package", "return", "super", "this", "throw", "true", "try", "typeof", "val", "var", "when", "while", "import", "catch", "finally"]

-- | Words the Kotlin grammar always reads as keywords, even where Kotlin
-- reads them as names (lawspec.data.Point, value: Int).
never :: [Text]
never = ["data", "value", "set", "get", "inner", "actual", "expect"]

-- | Modifier keywords, which are names elsewhere.
modifiers :: [Text]
modifiers = ["public", "private", "protected", "internal", "abstract", "final", "open", "sealed", "data", "enum", "annotation", "inner", "value", "companion", "override", "lateinit", "const", "suspend", "inline", "noinline", "crossinline", "operator", "infix", "tailrec", "external", "expect", "actual", "vararg", "reified", "out", "fun"]

-- | Declarations, imports and contextual keywords in a sequence of trees,
-- and in everything nested in them.
scan :: Position -> Text -> [Tree] -> [Node]
scan table source = go Nothing
  where
    go _ [] = []
    go previous trees@(tree : rest)
      | Just (prefix, keyword, after) <- declarationAt previous trees =
          let (nodes, remaining) = declared trees prefix keyword after
           in nodes ++ go Nothing remaining
      | isAtom "import" tree,
        notMember previous =
          let (line, remaining) = span (\t -> lineAt table (treeStart t) == lineAt table (treeStart tree)) rest
              path = takeWhile (\t -> not (isAtom "as" t)) line
              path' = reverse (dropWhile (\t -> isAtom "*" t || isAtom "." t) (reverse path))
           in [Node (treeStart tree) (maybe (treeEnd tree) treeEnd (lastOf line)) 0 (ImportFact (spanText source path')) | not (null path')]
                ++ go Nothing remaining
      | Just node <- contextual previous trees = node : nested tree ++ go (Just tree) rest
      | otherwise = nested tree ++ go (Just tree) rest
    nested (Group _ inner _) = go Nothing inner
    nested _ = []
    notMember previous = maybe True (\p -> not (any (`isAtom` p) [".", "?.", "::"])) previous
    -- A declaration keyword after a run of modifiers and annotations.
    declarationAt previous trees
      | notMember previous = case modifierRun trees of
          (prefix, Atom keyword : after)
            | leafText keyword `elem` ["class", "interface", "typealias"],
              Atom n : _ <- after,
              Just _ <- leafName n ->
                Just (prefix, keyword, after)
            | leafText keyword == "object",
              Atom n : _ <- after,
              Just _ <- leafName n,
              not (any (isAtom "companion") prefix) ->
                Just (prefix, keyword, after)
            | leafText keyword == "fun",
              not (startsGroup after) ->
                Just (prefix, keyword, after)
          _ -> Nothing
      | otherwise = Nothing
    startsGroup (t : _) = isGroup "(" t
    startsGroup [] = True
    declared trees prefix keywordLeaf after =
      let keyword = leafText keywordLeaf
          start = maybe 0 treeStart (listToMaybe trees)
          keywordNodes = [Node (treeStart t) (treeEnd t) 0 KeywordFact | t <- prefix, isModifierWord t]
       in case keyword of
            "fun" ->
              let (signature, rest) = break (isGroup "(") after
                  -- The function's name is the word before its parameters;
                  -- the grammar names it even where it reads it as a keyword.
                  name' = case lastOf signature of
                    Just (Atom l) | leafKind l `elem` [Name, Word] -> Just (leafText l)
                    _ -> Nothing
               in case rest of
                    parameters : afterParameters ->
                      let (tailTrees, remaining) = functionTail parameters afterParameters
                          end = maybe (treeEnd parameters) treeEnd (lastOf tailTrees)
                       in ( [declaration start end "function_declaration" n False | Just n <- [name']]
                              ++ keywordNodes
                              ++ concatMap nested prefix
                              ++ concatMap nested signature
                              ++ nested parameters
                              ++ go Nothing tailTrees,
                            remaining
                          )
                    [] -> (keywordNodes ++ concatMap nested signature, [])
            "typealias" ->
              let (line, remaining) = logical (Atom keywordLeaf) after
                  name' = fromMaybe "" (listToMaybe [n | Atom l <- take 1 line, Just n <- [leafName l]])
               in ( declaration start (maybe start treeEnd (lastOf line)) "type_alias" name' True
                      : keywordNodes
                      ++ go Nothing (drop 1 line),
                    remaining
                  )
            _ ->
              let name' = fromMaybe "" (listToMaybe [n | Atom l <- take 1 after, Just n <- [leafName l]])
                  (header, remaining) = classTail (take 1 after) (drop 1 after)
                  kind = if keyword == "object" then "object_declaration" else "class_declaration"
                  end = maybe (maybe start treeEnd (listToMaybe after)) treeEnd (lastOf header)
               in ( declaration start end kind name' (keyword /= "object")
                      : keywordNodes
                      ++ concatMap nested prefix
                      ++ headerKeywords header
                      ++ go Nothing header,
                    remaining
                  )
    headerKeywords header = [Node (treeStart t) (treeEnd t) 0 KeywordFact | t <- header, any (`isAtom` t) ["where", "by"]]
    -- A function's return type, constraints and body.
    functionTail previous trees =
      let (signature, rest) = signatureLine previous trees
       in case rest of
            body : remaining | isGroup "{" body -> (signature ++ [body], remaining)
            equals : more
              | isAtom "=" equals ->
                  let (expression, remaining) = logical equals more
                   in (signature ++ equals : expression, remaining)
            _ -> (signature, rest)
    -- The trees of a declaration header on its logical line, up to a body.
    signatureLine previous trees =
      let (line, remaining) = logical previous trees
          (signature, body) = break (\t -> isGroup "{" t || isAtom "=" t) line
       in case body of
            [] -> case remaining of
              next : more
                | isGroup "{" next -> (signature, next : more)
              _ -> (signature, remaining)
            _ -> (signature, body ++ remaining)
    classTail previous trees =
      let (signature, rest) = case previous of
            [p] -> signatureLine p trees
            _ -> ([], trees)
       in case rest of
            body : remaining | isGroup "{" body -> (signature ++ [body], remaining)
            _ -> (signature, rest)
    -- Trees to the end of the logical line: a line break ends it unless
    -- the line ends with an operator or the next one starts with one.
    logical start trees = case walk [start] trees of
      (_ : line, remaining) -> (line, remaining)
      ([], remaining) -> ([], remaining)
      where
        walk acc [] = (reverse acc, [])
        walk acc@(previous : _) (next : more)
          | lineAt table (treeEnd previous) == lineAt table (treeStart next)
              || continues previous next =
              walk (next : acc) more
          | otherwise = (reverse acc, next : more)
        walk [] more = ([], more)
    continues previous next =
      any (`isAtom` previous) ["=", "+", "-", "*", "/", "%", "&&", "||", "?:", ".", "?.", "->", ",", ":", "::", "<", "if", "else", "when", "in", "is", "as", "!", "..", "..<", "==", "!=", "===", "!==", "<=", ">=", "return", "throw", "@"]
        || any (`isAtom` next) [".", "?.", "?:", "&&", "||", "else", ":", "where", "by", "as", "..", "..<", "catch", "finally"]
        || (isGroup "(" previous && False)
    -- Accessors and delegation use names that are keywords there.
    contextual previous trees = case trees of
      Atom w : next : _
        | leafText w `elem` ["get", "set"],
          isGroup "(" next,
          maybe True (\p -> not (any (`isAtom` p) [".", "?.", "::"])) previous,
          maybe True (\p -> lineAt table (treeEnd p) /= lineAt table (leafStart w) || isAtom ")" p || isAtom "val" p) previous ->
            Just (Node (leafStart w) (leafEnd w) 0 KeywordFact)
      Atom w : next : _
        | leafText w == "init",
          isGroup "{" next ->
            Just (Node (leafStart w) (leafEnd w) 0 KeywordFact)
      Atom w : next : _
        | leafText w `elem` modifiers,
          leafText w /= "fun",
          notMember previous,
          lineAt table (leafEnd w) == lineAt table (treeStart next),
          any (`isAtom` next) (["val", "var", "fun", "class", "interface", "object", "constructor", "typealias"] ++ modifiers) ->
            Just (Node (leafStart w) (leafEnd w) 0 KeywordFact)
      Atom w : _
        | leafText w `elem` ["by", "where", "out", "reified", "vararg", "crossinline", "noinline"],
          notMember previous ->
            Just (Node (leafStart w) (leafEnd w) 0 KeywordFact)
      _ -> Nothing
    -- Modifier words and annotations ahead of a keyword; a modifier word
    -- shares a line with what follows it.
    modifierRun trees = run [] trees
      where
        run acc (tree@(Atom leaf) : next : more)
          | leafText leaf `elem` modifiers,
            leafText leaf /= "fun" || isInterface next,
            lineAt table (leafEnd leaf) == lineAt table (treeStart next) =
              run (tree : acc) (next : more)
          | leafText leaf == "@" = annotation (tree : acc) (next : more)
        run acc rest = (reverse acc, rest)
        annotation acc (n@(Atom _) : colon : target : more)
          | isAtom ":" colon = annotation' (target : colon : n : acc) more
        annotation acc (n@(Atom _) : more) = annotation' (n : acc) more
        annotation acc (g : more) | isGroup "[" g = run (g : acc) more
        annotation acc more = (reverse acc, more)
        annotation' acc (dot : n@(Atom _) : more) | isAtom "." dot = annotation' (n : dot : acc) more
        annotation' acc (g : more) | isGroup "(" g = run (g : acc) more
        annotation' acc more = run acc more
        isInterface next = isAtom "interface" next
    isModifierWord (Atom leaf) = leafText leaf `elem` modifiers && leafText leaf /= "fun"
    isModifierWord _ = False

lastOf :: [a] -> Maybe a
lastOf = listToMaybe . reverse

spanText :: Text -> [Tree] -> Text
spanText _ [] = ""
spanText source trees@(first : _) = slice source (treeStart first) (maybe (treeEnd first) treeEnd (lastOf trees))
