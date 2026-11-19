-- | F# declarations and module names for authoring advice: the
-- @function_or_value_defn@ of each let (and let!) at any depth, the
-- @type_definition@ of each type chain that holds a record or union, and
-- the @named_module@ of a file that starts with module. The F# grammar has
-- no node the advice reads as an import (open declarations are
-- @import_decl@).
--
-- Spans follow the offside rule: a let or type reaches the line before
-- the next line that starts at or left of its keyword (an and, or a union
-- case's bar, continues it), or an in that closes it. A let's name is the
-- grammar's: its identifier, else (for operators, active patterns, tuples
-- and other patterns) the first identifier of a body that is only a
-- dotted name. A type chain's name is the text of the first record or
-- union's type name, with its access modifier and type parameters; class,
-- interface, enum, delegate and abbreviation definitions name nothing, and
-- a chain of only those is no declaration, as in the grammar (which reads
-- an abbreviation to a lone name, type T = int, as a union).
--
-- Strings contribute their delimiters (and interpolated code) as leaves,
-- not their text, and numbers split as the grammar's leaves do: a float at
-- its point and exponent sign, some type suffixes as leaves of their own,
-- others dropped.
--
-- Limits: the grammar's zero-width layout separators are not leaves;
-- undentation the offside rule permits after infix operators is read as
-- the end of a definition; an in is matched to the innermost open let or
-- for.
-- ref:DEC-authoring-advisories
module LawSpec.Authoring.Languages.FSharp (facts) where

import Control.Monad (void)
import Data.Char (isAlpha, isAlphaNum, isDigit, isHexDigit)
import qualified Data.IntSet as IS
import Data.List (tails)
import Data.Maybe (isJust, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import LawSpec.Authoring.Syntax
import Text.Megaparsec
import Text.Megaparsec.Char (char, string)

facts :: Text -> Facts
facts source = case lexSource space (const fsToken) source of
  Left problem -> unreadable problem
  Right leaves' ->
    let leaves = contextual table leaves'
     in case brackets [("(", ")"), ("[", "]"), ("{", "}")] leaves of
          Left problem -> unreadable problem
          Right trees ->
            let starts = lineStarts table leaves
             in assemble source leaves (moduleOf source trees ++ scan source table starts trees)
  where
    table = position source
    unreadable problem = failed ("Native syntax could not be read: " <> T.pack problem)

-- | Words whose leaf type depends on their place: property accessors
-- (with get, set) and a not struct constraint are keywords; the pattern
-- of use, and a member's self identifier _, are names.
contextual :: Position -> [Leaf] -> [Leaf]
contextual table leaves = zipWith3 adjust (Nothing : Nothing : map Just leaves) (Nothing : map Just leaves) (zip leaves (map Just (drop 1 leaves) ++ [Nothing]))
  where
    adjust before previous (leaf, next)
      | leafText leaf `elem` ["get", "set"],
        accessor (fmap leafText previous) (fmap leafText before) =
          leaf {leafKind = Word, leafName = Nothing}
      | leafText leaf == "not",
        fmap leafText previous == Just ":",
        fmap leafText next `elem` [Just "struct", Just "null"] =
          leaf {leafKind = Word, leafName = Nothing}
      | leafText leaf == "_",
        fmap leafText previous `elem` [Just "use", Just "use!"]
          || (fmap leafText previous == Just "member" && fmap leafText next == Just ".")
          || laterArm previous before =
          leaf {leafKind = Name, leafName = Just "_"}
      | otherwise = leaf
    -- The grammar reads a match arm after the first on the same line as
    -- an infix expression, whose _ is a name.
    laterArm (Just bar) before =
      leafText bar == "|"
        && maybe False (\b -> lineAt table (leafEnd b) == lineAt table (leafStart bar) && leafText b `notElem` ["with", "function"]) before
    laterArm _ _ = False
    accessor previous before =
      previous `elem` [Just "with", Just "and"]
        || (previous == Just "," && before `elem` [Just "get", Just "set"])

-- | The offsets of the leaves that start their lines.
lineStarts :: Position -> [Leaf] -> IS.IntSet
lineStarts table leaves =
  IS.fromList
    [ leafStart leaf
    | (previous, leaf) <- zip (Nothing : map Just leaves) leaves,
      maybe True (\p -> lineAt table (leafEnd p) < lineAt table (leafStart leaf)) previous
    ]

operatorChar :: Char -> Bool
operatorChar c = c `elem` ("!$%&*+-./<=>?@^|~:#" :: String)

-- | Whitespace and comments (an operator in parentheses, (*), is not one).
space :: Lexer ()
space =
  skipMany
    ( void (takeWhile1P Nothing (\c -> c == ' ' || c == '\t' || c == '\n' || c == '\r'))
        <|> try (lineComment "//")
        <|> try (notFollowedBy (string "(*)") *> blockComment True "(*" "*)")
    )

fsToken :: Lexer [Leaf]
fsToken =
  choice
    [ try stringLiteral,
      (: []) <$> try (plain characterLiteral),
      number,
      (: []) <$> try operatorName,
      (: []) <$> identifier,
      (: []) <$> symbol (T.pack <$> some (satisfy operatorChar) <|> (T.singleton <$> anySingle))
    ]

-- | A numeric literal as the grammar's leaves: a float's parts split at
-- its point and exponent sign, the type suffixes L, y, uy, s, us, n, un and
-- l as leaves of their own, and the suffixes u, UL, I, M, m and f dropped.
-- An integer's exponent (1e3) is left to be read as a name, as the grammar
-- reads it.
number :: Lexer [Leaf]
number = do
  prefixed <- optional (try (plain (T.append <$> (string "0x" <|> string "0X" <|> string "0o" <|> string "0b") <*> takeWhile1P Nothing (\c -> isHexDigit c || c == '_'))))
  case prefixed of
    Just leaf -> (leaf :) <$> suffix
    Nothing -> do
      whole <- plain (T.cons <$> satisfy isDigit <*> takeWhileP Nothing (\c -> isDigit c || c == '_'))
      fraction <- optional (try ((,) <$> symbol (string "." <* lookAhead (satisfy isDigit)) <*> plain (takeWhile1P Nothing (\c -> isDigit c || c == '_'))))
      case fraction of
        Just (point, digits) -> do
          exponent' <- optional (try ((,) <$> plain (T.append <$> (string "e" <|> string "E") <*> (string "-" <|> string "+")) <*> plain (takeWhile1P Nothing isDigit)))
          rest <- suffix
          pure ([whole, point, digits] ++ maybe [] (\(e, d) -> [e, d]) exponent' ++ rest)
        Nothing -> (whole :) <$> suffix
  where
    suffix = do
      text <- lookAhead (takeWhileP Nothing isAlpha)
      if text `elem` ["L", "y", "uy", "s", "us", "n", "un", "l"]
        then (: []) <$> word (string text)
        else
          if text `elem` ["u", "U", "UL", "ul", "uL", "I", "M", "m", "f", "F"]
            then [] <$ string text
            else pure []

-- | An operator named in parentheses, (+) or ( * ): one name leaf.
operatorName :: Lexer Leaf
operatorName = do
  start <- getOffset
  _ <- char '('
  inner <- takeWhileP Nothing (== ' ')
  op <- takeWhile1P Nothing operatorChar
  after <- takeWhileP Nothing (== ' ')
  _ <- char ')'
  end <- getOffset
  -- An active pattern's banana clips hold names, not an operator.
  if op `elem` ["|", "||"] then fail "not an operator" else pure ()
  let text = "(" <> inner <> op <> after <> ")"
  pure (Leaf Name text (Just text) start end)

keywords :: [Text]
keywords =
  [ "abstract",
    "and",
    "as",
    "assert",
    "begin",
    "class",
    "default",
    "delegate",
    "do",
    "done",
    "downcast",
    "downto",
    "elif",
    "else",
    "end",
    "exception",
    "extern",
    "false",
    "finally",
    "fixed",
    "for",
    "fun",
    "function",
    "global",
    "if",
    "in",
    "inherit",
    "inline",
    "interface",
    "internal",
    "lazy",
    "let",
    "match",
    "member",
    "module",
    "mutable",
    "new",
    "null",
    "of",
    "open",
    "or",
    "override",
    "private",
    "public",
    "rec",
    "return",
    "sig",
    "static",
    "struct",
    "then",
    "to",
    "true",
    "try",
    "type",
    "upcast",
    "use",
    "val",
    "void",
    "when",
    "while",
    "with",
    "yield",
    "_",
    "let!",
    "use!",
    "do!",
    "yield!",
    "return!",
    "match!",
    "and!"
  ]

identifier :: Lexer Leaf
identifier = do
  start <- getOffset
  text <-
    (\body -> "``" <> body <> "``")
      <$> (string "``" *> takeWhileP Nothing (/= '`') <* string "``")
      <|> word'
  end <- getOffset
  -- The namespace keyword's leaf type, namespace, reads as a name.
  let keyword = text `elem` keywords
  pure (Leaf (if keyword then Word else Name) text (if keyword then Nothing else Just text) start end)
  where
    word' = do
      text <- identifierWith (\c -> isAlpha c || c == '_') (\c -> isAlphaNum c || c == '_' || c == '\'')
      -- let!, use!, do!, yield!, return!, match!, and!
      bang <- if text `elem` ["let", "use", "do", "yield", "return", "match", "and"] then option "" (try (string "!" <* notFollowedBy (char '='))) else pure ""
      pure (text <> bang)

characterLiteral :: Lexer Text
characterLiteral = do
  _ <- char '\''
  body <- (T.cons <$> char '\\' <*> takeWhile1P Nothing (/= '\'')) <|> (T.singleton <$> anySingle)
  _ <- char '\''
  suffix <- option "" (string "B")
  pure ("'" <> body <> "'" <> suffix)

-- | A string's leaves: its delimiters and any interpolated code.
stringLiteral :: Lexer [Leaf]
stringLiteral = do
  start <- getOffset
  prefix <- choice (map (try . string) ["$@", "@$", "$", "@", ""])
  quote <- choice [try (string "\"\"\""), string "\""]
  openEnd <- getOffset
  let interpolated = "$" `T.isInfixOf` prefix
      verbatim = "@" `T.isInfixOf` prefix || quote == "\"\"\""
  inner <- body interpolated verbatim quote
  closeStart <- getOffset
  _ <- string quote
  suffix <- option "" (string "B")
  closeEnd <- getOffset
  pure ([Leaf Symbol (prefix <> quote) Nothing start openEnd] ++ inner ++ [Leaf Symbol (quote <> suffix) Nothing closeStart closeEnd])
  where
    body interpolated verbatim quote = concat <$> many (piece interpolated verbatim quote)
    piece interpolated verbatim quote =
      choice
        [ [] <$ try (string "{{") <* guardInterpolated interpolated,
          [] <$ try (string "}}") <* guardInterpolated interpolated,
          if interpolated then interpolation else empty,
          [] <$ try (if verbatim && quote == "\"" then string "\"\"" else empty),
          [] <$ try (if verbatim then empty else char '\\' *> anySingle),
          [] <$ (notFollowedBy (string quote) *> anySingle)
        ]
    guardInterpolated interpolated = if interpolated then pure () else fail "plain"
    interpolation = do
      open <- symbol (string "{")
      code <- expression (0 :: Int)
      close <- symbol (string "}")
      pure ([open] ++ code ++ [close])
    -- The code of an interpolation, up to its closing brace (a format
    -- after a colon is text).
    expression depth = do
      space
      next <- lookAhead (optional anySingle)
      case next of
        Nothing -> pure []
        Just '}' | depth == 0 -> pure []
        Just ':' | depth == 0 -> [] <$ takeWhileP Nothing (/= '}')
        _ -> do
          leaves <- fsToken
          let depth' = depth + sum [delta (leafText l) | l <- leaves, leafKind l == Symbol]
          (leaves ++) <$> expression depth'
    delta t
      | t `elem` ["(", "[", "{"] = 1
      | t `elem` [")", "]", "}"] = -1
      | otherwise = 0 :: Int

-- | A file's module name.
moduleOf :: Text -> [Tree] -> [Node]
moduleOf source trees = case trees of
  first : rest
    | isAtom "module" first ->
        let name' = takeWhile isNamePart (dropWhile modifier rest)
            after = drop (length name') (dropWhile modifier rest)
         in case (name', after) of
              (_ : _, next : _) | isAtom "=" next -> []
              (n : _, _) -> [Node (treeStart first) (maybe (treeEnd n) treeEnd (lastOf trees)) 0 (ModuleFact (spanOf source name'))]
              _ -> []
  _ -> []
  where
    modifier t = any (`isAtom` t) ["rec", "private", "internal", "public"]
    isNamePart t = isJust (nameOf t) || isAtom "." t

nameOf :: Tree -> Maybe Text
nameOf (Atom leaf) = leafName leaf
nameOf _ = Nothing

lastOf :: [a] -> Maybe a
lastOf [] = Nothing
lastOf xs = Just (last xs)

spanOf :: Text -> [Tree] -> Text
spanOf _ [] = ""
spanOf source trees@(first : _) = slice source (treeStart first) (treeEnd (last trees))

-- | Every let and type in a sequence, and in the groups it holds.
scan :: Text -> Position -> IS.IntSet -> [Tree] -> [Node]
scan source table starts trees = concat (zipWith3 visit (inits' trees) trees (drop 1 (tails trees)))
  where
    -- The trees before each tree, nearest first.
    inits' = scanl (flip (:)) []
    visit before tree after = case tree of
      Group _ inner _ -> scan source table starts inner
      Atom leaf
        | leafText leaf `elem` ["let", "let!"] -> letNode after leaf
        | leafText leaf == "type" -> typeNode before after leaf
      _ -> []
    column leaf = columnAt table (leafStart leaf)
    startsLine tree = IS.member (treeStart tree) starts
    -- The trees a definition spans after its keyword: to the first line
    -- that starts at or left of the keyword (but an and, or a bar for a
    -- type, continues it), or the in that closes it.
    extent continues keyword after =
      let go _ _ [] = []
          go opened fors (t : rest)
            | startsLine t,
              treeColumn t <= column keyword,
              not (any (`isAtom` t) continues) =
                []
            | isAtom "in" t, fors > 0 = t : go opened' (fors - 1) rest
            | isAtom "in" t = case opened' of
                _ : more -> t : go more fors rest
                [] -> []
            | isAtom "for" t = t : go opened' (fors + 1) rest
            | any (`isAtom` t) ["let", "let!", "use", "use!"] = t : go (treeColumn t : opened') fors rest
            | otherwise = t : go opened' fors rest
            where
              opened' = if startsLine t then filter (< treeColumn t) opened else opened
       in go [] (0 :: Int) after
    treeColumn t = columnAt table (treeStart t)
    letNode after keyword =
      let spanned = extent ["and"] keyword after
          end = maybe (leafEnd keyword) treeEnd (lastOf spanned)
          parts = statements (isAtom "and") spanned
       in case listToMaybe [n | Just n <- map letName parts] of
            Just name' -> [declaration (leafStart keyword) end "function_or_value_defn" name' False]
            Nothing -> []
    -- A let's name: from its left-hand side, else from a body that is
    -- only a dotted name.
    letName part =
      let left = dropWhile (\t -> any (`isAtom` t) ["rec", "inline", "mutable", "private", "internal", "public"]) (takeWhile (not . isAtom "=") part)
          body = drop 1 (dropWhile (not . isAtom "=") part)
       in case left of
            first : rest
              | Just name' <- nameOf first,
                name' /= "_",
                not ("(" `T.isPrefixOf` name'),
                maybe True (\t -> not (any (`isAtom` t) [",", "::", "as", "|"])) (listToMaybe rest) ->
                  Just name'
            Group open _ _ : _ | leafText open == "[" -> Nothing
            _ | dotted body -> nameOf =<< listToMaybe body
            _ -> Nothing
    dotted body = case body of
      first : rest -> isJust (nameOf first) && pairs rest
      [] -> False
      where
        pairs (dot : name' : more) = isAtom "." dot && isJust (nameOf name') && pairs more
        pairs [] = True
        pairs _ = False
    typeNode before after keyword =
      let spanned = extent ["and", "|"] keyword after
          end = maybe (leafEnd keyword) treeEnd (lastOf spanned)
          attributes = takeWhile isAttribute before
          start = maybe (leafStart keyword) treeStart (lastOf attributes)
          definitions = statements (isAtom "and") spanned
       in case listToMaybe [n | Just n <- map typeName definitions] of
            Just name' -> [declaration start end "type_definition" name' True]
            Nothing -> []
    isAttribute (Group open (Atom lt : _) _) = leafText open == "[" && "<" `T.isPrefixOf` leafText lt
    isAttribute _ = False
    -- A record or union definition's type name, with its access modifier
    -- and type parameters.
    typeName definition =
      let header = dropWhile isAttribute (takeWhile (not . isAtom "=") definition)
          name' = takeWhile (\t -> not (isGroup "(" t || isAtom ":" t || isAtom "as" t || isAtom "when" t)) header
          representation = dropWhile (\t -> any (`isAtom` t) ["private", "internal", "public"]) (drop 1 (dropWhile (not . isAtom "=") definition))
       in if not (null name') && (record representation || union representation)
            then Just (spanOf source name')
            else Nothing
    record (Group open inner _ : _) = leafText open == "{" && maybe True (not . isAtom "|") (listToMaybe inner)
    record _ = False
    union representation =
      let cases = statements (isAtom "|") (takeWhile (not . isAtom "with") representation)
          startsWithBar = maybe False (isAtom "|") (listToMaybe representation)
       in not (null cases)
            && all unionCase cases
            && (startsWithBar || length cases > 1 || all singleCase cases)
    unionCase (first : rest) =
      isJust (nameOf first)
        && not (any (isAtom "=") rest)
        && case rest of
          [] -> True
          next : _ -> isAtom "of" next || isAtom ":" next
    unionCase [] = False
    singleCase [_] = True
    singleCase (_ : next : _) = isAtom "of" next
    singleCase [] = False
