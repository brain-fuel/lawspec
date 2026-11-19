-- | Scala declarations, imports and package names for authoring advice:
-- the class, object, trait, enum, type and function definitions of the
-- Scala grammar at any depth (an abstract def without a body is a
-- declaration the advice does not read), the first name of each import
-- path, and package clauses. Definitions are found by their keywords after
-- any annotations and modifiers; a definition without braces ends at the
-- end of its statement, by Scala's semicolon inference as far as tokens
-- show it. Braceless (indentation) syntax is outside the recognised
-- forms. The extractor does not resolve names or types.
-- ref:DEC-authoring-advisories
module LawSpec.Authoring.Languages.Scala (facts) where

import Data.Char (isAlpha, isAlphaNum, isDigit)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import LawSpec.Authoring.Languages.Kotlin (interpolation)
import LawSpec.Authoring.Syntax
import Text.Megaparsec
import Text.Megaparsec.Char (char, string)

facts :: Text -> Facts
facts source = case scalaLeaves source of
  Left problem -> unreadable problem
  Right leaves -> case brackets [("(", ")"), ("[", "]"), ("{", "}")] leaves of
    Left problem -> unreadable problem
    Right trees -> assemble source leaves (scan (position source) source trees)
  where
    unreadable problem = failed ("Native syntax could not be read: " <> T.pack problem)

scalaLeaves :: Text -> Either String [Leaf]
scalaLeaves = lexSource space step
  where
    space = spaces [lineComment "//", blockComment True "/*" "*/"]
    step previous =
      choice
        [ try interpolated,
          (: []) <$> plain (string "\"\"\"" <> rawBody),
          (: []) <$> plain plainString,
          (: []) <$> plain (try characterLiteral),
          (: []) <$> plain numberLike,
          (: []) <$> try (negative previous),
          (: []) <$> identifier,
          (: []) <$> name (backticked <$> (char '`' *> takeWhile1P Nothing (/= '`') <* char '`')),
          (: []) <$> operator previous,
          (: []) <$> symbol (T.singleton <$> anySingle)
        ]
    backticked text = "`" <> text <> "`"
    rawBody = do
      body <- manyTill anySingle (lookAhead (try closing))
      quotes <- closing
      pure (T.pack body <> quotes)
    -- A raw string closes at its last three quotes in a run.
    closing = do
      quotes <- takeWhile1P Nothing (== '"')
      if T.length quotes >= 3 then pure quotes else fail "not a close"
    plainString = do
      _ <- char '"'
      body <- many ((T.cons '\\' . T.singleton <$> (char '\\' *> anySingle)) <|> (T.singleton <$> satisfy (\c -> c /= '"' && c /= '\\' && c /= '\n')))
      _ <- char '"'
      pure ("\"" <> T.concat body <> "\"")
    interpolated = do
      interpolator <- name (identifierWith isAlpha (\c -> isAlphaNum c || c == '_'))
      rest <-
        delimited (string "\"\"\"") (string "\"\"\"") [dollar] (\c -> c == '"' || c == '$')
          <|> delimited (string "\"") (string "\"") [escape, dollar] (\c -> c == '"' || c == '$' || c == '\\')
      pure (interpolator : rest)
    dollar =
      ((: []) <$> plain (string "$$"))
        <|> interpolation space step
        <|> do
          sign <- plain (string "$")
          named <- name (identifierWith (\c -> isAlpha c || c == '_') (\c -> isAlphaNum c))
          pure [sign, named]
    characterLiteral = do
      _ <- char '\''
      body <- (T.cons '\\' <$> (char '\\' *> takeWhile1P Nothing (/= '\''))) <|> (T.singleton <$> anySingle)
      _ <- char '\''
      pure ("'" <> body <> "'")
    identifier = do
      start <- getOffset
      text <- identifierWith (\c -> isAlpha c || c == '_' || c == '$') (\c -> isAlphaNum c || c == '_' || c == '$')
      -- An identifier may end in an operator after an underscore (b_=).
      suffix <- if T.length text > 1 && T.isSuffixOf "_" text then takeWhileP Nothing isOperatorCharacter else pure ""
      end <- getOffset
      let text' = text <> suffix
          keyword = text' `elem` reserved
      pure (Leaf (if keyword then Word else Name) text' (if keyword then Nothing else Just text') start end)
    -- A minus sign after a space and before a digit is part of a
    -- literal (1 by -1, then -1L).
    negative previous = do
      offset <- getOffset
      _ <- char '-'
      _ <- lookAhead (satisfy isDigit)
      if maybe True (\p -> leafEnd p < offset || leafText p `elem` ["(", "[", "{", ","]) previous
        then plain (("-" <>) <$> numberLike)
        else fail "an operator"
    -- Operators are names where the grammar reads them as operator
    -- identifiers: infix, after a member access, or defined by def.
    operator previous = do
      start <- getOffset
      text <- takeWhile1P Nothing isOperatorCharacter
      end <- getOffset
      let named = text == "?" || text `notElem` reservedOperators && maybe False operand previous
      pure (Leaf (if named then Name else Symbol) text (if named then Just text else Nothing) start end)
    operand leaf =
      (leafKind leaf == Name && not (T.all isOperatorCharacter (leafText leaf)))
        || leafKind leaf == Literal
        || leafText leaf `elem` [")", "]", "}", ".", "def", "this", "_", "null", "true", "false", "super", "end", "open"]

isOperatorCharacter :: Char -> Bool
isOperatorCharacter c = c `elem` ("!#%&*+-/:<=>?@\\^|~" :: String)

reserved :: [Text]
reserved = ["abstract", "case", "catch", "class", "def", "do", "else", "enum", "export", "extends", "false", "final", "finally", "for", "forSome", "given", "if", "implicit", "import", "lazy", "match", "new", "null", "object", "override", "package", "private", "protected", "return", "sealed", "throw", "trait", "true", "try", "type", "val", "var", "while", "with", "yield", "then", "_", "open", "end"]

reservedOperators :: [Text]
reservedOperators = ["=", "=>", "<-", ":", "<:", ">:", "#", "@", "<%", "?=>", "=>>"]

modifiers :: [Text]
modifiers = ["abstract", "final", "sealed", "implicit", "lazy", "override", "private", "protected", "case", "inline", "opaque", "open", "transparent", "infix"]

scan :: Position -> Text -> [Tree] -> [Node]
scan table source = go Nothing
  where
    go _ [] = []
    go previous trees@(tree : rest)
      | notMember previous,
        Just (prefix, keyword, after) <- definitionAt trees =
          let (nodes, remaining) = defined trees prefix keyword after
           in nodes ++ go Nothing remaining
      | isAtom "import" tree,
        notMember previous =
          let (line, remaining) = extent tree rest
           in [Node (treeStart tree) (maybe (treeEnd tree) treeEnd (lastOf line)) 0 (ImportFact (leafText l)) | Atom l : _ <- [line]]
                ++ [Node (treeStart t) (treeEnd t) 0 KeywordFact | (dot, t) <- zip line (drop 1 line), isAtom "." dot, any (`isAtom` t) ["*", "_", "given"]]
                ++ concatMap nested line
                ++ go Nothing remaining
      | isAtom "package" tree,
        notMember previous =
          let (path, remaining) = span (\t -> isAtom "." t || maybe False (const True) (atomName t)) rest
           in [Node (treeStart tree) (maybe (treeEnd tree) treeEnd (lastOf path)) 0 (ModuleFact (spanText source path)) | not (null path)]
                ++ go Nothing remaining
      | isAtom "case" tree = casePattern rest
      | Atom leaf <- tree,
        leafKind leaf == Name,
        T.all isOperatorCharacter (leafText leaf),
        leafText leaf /= "?",
        maybe True (\t -> isAtom "," t) (listToMaybe rest) =
          Node (leafStart leaf) (leafEnd leaf) 0 KeywordFact : go (Just tree) rest
      | Just node <- contextual previous trees = node : nested tree ++ go (Just tree) rest
      | otherwise = nested tree ++ go (Just tree) rest
    nested (Group _ inner _) = go Nothing inner
    nested _ = []
    notMember previous = maybe True (\p -> not (isAtom "." p)) previous
    atomName (Atom l) = leafName l
    atomName _ = Nothing
    -- A case pattern's alternatives are punctuation there.
    casePattern rest =
      let (pattern, after) = break (isAtom "=>") rest
       in [Node (treeStart t) (treeEnd t) 0 KeywordFact | t <- pattern, isAtom "|" t]
            ++ concatMap nested pattern
            ++ go Nothing after
    contextual previous trees = case trees of
      Atom w : _
        | leafText w == "using",
          maybe True (const False) previous ->
            Just (Node (leafStart w) (leafEnd w) 0 KeywordFact)
      Atom w : next : _
        | leafText w == "end",
          firstOnLine previous (Atom w),
          lineAt table (leafEnd w) == lineAt table (treeStart next) ->
            Just (Node (leafStart w) (leafEnd w) 0 KeywordFact)
      _ -> Nothing
    firstOnLine previous tree = maybe True (\p -> lineAt table (treeEnd p) < lineAt table (treeStart tree)) previous
    definitionAt trees = case modifierRun trees of
      (prefix, Atom keyword : Atom n : after)
        | leafText keyword `elem` ["class", "object", "trait", "enum", "type", "def"],
          leafKind n `elem` [Name, Word] || leafText keyword == "def" ->
            Just (prefix, keyword, Atom n : after)
      _ -> Nothing
    defined trees prefix keywordLeaf after =
      let keyword = leafText keywordLeaf
          first = fromMaybe (Atom keywordLeaf) (listToMaybe trees)
          start = treeStart first
          name' = fromMaybe "" (listToMaybe [leafText l | Atom l <- take 1 after])
          (whole, remaining) = extent first (drop (length prefix + 1) trees)
          modifierNodes = [Node (treeStart t) (treeEnd t) 0 KeywordFact | t <- prefix, isSoftModifier t]
          around = modifierNodes ++ concatMap nested prefix
          endOf = maybe (treeEnd (Atom keywordLeaf)) treeEnd . lastOf
       in case keyword of
            "def" ->
              let signature = takeWhile (\t -> not (isAtom "=" t || isGroup "{" t)) (drop 1 whole)
                  rest = drop (1 + length signature) whole
                  procedure block remaining' =
                    (declaration start (treeEnd block) "function_definition" name' False : around ++ concatMap nested signature ++ nested block, remaining')
               in case (rest, remaining) of
                    (equals : _, _)
                      | isAtom "=" equals ->
                          (declaration start (endOf whole) "function_definition" name' False : around ++ go Nothing (drop 1 whole), remaining)
                    (block : more, _) | isGroup "{" block -> procedure block (more ++ remaining)
                    ([], block : more) | isGroup "{" block -> procedure block more
                    _ -> (around ++ go Nothing (drop 1 whole), remaining)
            "type" ->
              (declaration start (endOf whole) "type_definition" name' True : around ++ go Nothing (drop 1 whole), remaining)
            _ ->
              let header = classHeader whole
                  rest = drop (length header) whole
                  kind = case keyword of
                    "class" -> "class_definition"
                    "object" -> "object_definition"
                    "trait" -> "trait_definition"
                    _ -> "enum_definition"
                  model = keyword `elem` ["class", "enum"]
                  braced body remaining' =
                    (declaration start (treeEnd body) kind name' model : around ++ go Nothing (drop 1 header) ++ nested body, remaining')
               in case (rest, remaining) of
                    (body : more, _) | isGroup "{" body, not (endsWithColon header) -> braced body (more ++ remaining)
                    ([], body : more) | isGroup "{" body, not (endsWithColon header) -> braced body more
                    _ -> (declaration start (endOf whole) kind name' model : around ++ go Nothing (drop 1 whole), remaining)
    endsWithColon header = maybe False (isAtom ":") (lastOf header)
    -- A class header runs to its brace body, or to a colon that ends a
    -- line before an indented body.
    classHeader (tree : next : more)
      | isGroup "{" tree = []
      | isAtom ":" tree && lineAt table (treeEnd tree) < lineAt table (treeStart next) = [tree]
      | otherwise = tree : classHeader (next : more)
    classHeader [tree] | isGroup "{" tree = []
    classHeader trees = trees
    -- A definition's trees: those on its first line, and those on later
    -- lines that start further right than the line it starts on.
    extent first trees = walk first trees []
      where
        indent = indentation (treeStart first)
        walk _ [] acc = (reverse acc, [])
        walk previous (next : more) acc
          | lineAt table (treeEnd previous) == lineAt table (treeStart next) || columnAt table (treeStart next) > indent =
              walk next more (next : acc)
          | otherwise = (reverse acc, next : more)
    -- The column of the first token on an offset's line.
    indentation offset =
      let line = lineAt table offset
          lineStart = offset - columnAt table offset
          text = T.drop lineStart source
       in line `seq` T.length (T.takeWhile (\c -> c == ' ' || c == '\t') text)
    -- Annotations and modifiers ahead of a definition keyword.
    modifierRun = run []
      where
        run acc (tree@(Atom leaf) : next : more)
          | leafText leaf `elem` modifiers = case next of
              Group open _ _ | leafText open == "[" -> run (next : tree : acc) more
              _ -> run (tree : acc) (next : more)
          | leafText leaf == "@" = annotation (tree : acc) (next : more)
        run acc rest = (reverse acc, rest)
        annotation acc (n@(Atom _) : more) = annotation' (n : acc) more
        annotation acc more = (reverse acc, more)
        annotation' acc (dot : n@(Atom _) : more) | isAtom "." dot = annotation' (n : dot : acc) more
        annotation' acc (g : more) | isGroup "(" g = run (g : acc) more
        annotation' acc more = run acc more
    isSoftModifier (Atom leaf) = leafText leaf `elem` ["inline", "opaque", "open", "transparent", "infix"]
    isSoftModifier _ = False

lastOf :: [a] -> Maybe a
lastOf = listToMaybe . reverse

spanText :: Text -> [Tree] -> Text
spanText _ [] = ""
spanText source trees@(first : _) = slice source (treeStart first) (maybe (treeEnd first) treeEnd (lastOf trees))
