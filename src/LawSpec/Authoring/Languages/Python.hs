-- | Python declarations and imports for authoring advice: the
-- @class_definition@ and @function_definition@ nodes of the Python grammar
-- at any depth, and its @import_statement@ and @import_from_statement@
-- module names. A declaration spans its header to the end of its block,
-- found from the indentation of logical lines (brackets and backslashes
-- continue a line). Strings keep the grammar's leaves: a prefix and quote,
-- content (only its escape sequences when it has any), and the code of
-- f-string interpolations, which may hold names.
--
-- Limits: tabs count as one column; the Python 2 print statement and the
-- soft keyword type, and match and case outside a statement's start, are
-- read as names; a backslash in a
-- comment does not continue a line.
-- ref:DEC-authoring-advisories
module LawSpec.Authoring.Languages.Python (facts) where

import Control.Monad (void)
import Data.Array (Array, listArray, (!))
import Data.Char (isAlpha, isAlphaNum, isDigit, isHexDigit, isOctDigit, toLower)
import qualified Data.IntSet as IS
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import LawSpec.Authoring.Syntax
import Text.Megaparsec
import Text.Megaparsec.Char (char, string)

facts :: Text -> Facts
facts source = case lexSource space step source of
  Left problem -> unreadable problem
  Right leaves -> case brackets [("(", ")"), ("[", "]"), ("{", "}")] leaves of
    Left problem -> unreadable problem
    Right _ -> assemble source leaves (nodes source leaves)
  where
    unreadable problem = failed ("Native syntax could not be read: " <> T.pack problem)
    step _ = pyToken

-- | Whitespace, comments and backslash line continuations.
space :: Lexer ()
space = spaces [lineComment "#", void (string "\\\n"), void (string "\\\r\n")]

-- | The leaves of one pyToken.
pyToken :: Lexer [Leaf]
pyToken =
  choice
    [ try stringLiteral,
      (: []) <$> leafAt Literal (const Nothing) number,
      (: []) <$> identifier,
      (: []) <$> symbol (operatorFrom operators <|> (T.singleton <$> anySingle))
    ]
  where
    operators =
      ["...", "**=", "//=", ">>=", "<<=", "->", ":=", "**", "//", "<<", ">>", "<=", ">=", "==", "!=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "@="]

number :: Lexer Text
number = numberLike <|> try (T.cons <$> char '.' <*> takeWhile1P Nothing isDigit)

identifier :: Lexer Leaf
identifier = do
  start <- getOffset
  text <- identifierWith (\c -> isAlpha c || c == '_') (\c -> isAlphaNum c || c == '_')
  end <- getOffset
  let keyword = text `elem` keywords
  pure (Leaf (if keyword then Word else Name) text (if keyword then Nothing else Just text) start end)

keywords :: [Text]
keywords =
  [ "False",
    "None",
    "True",
    "and",
    "as",
    "assert",
    "async",
    "await",
    "break",
    "class",
    "continue",
    "def",
    "del",
    "elif",
    "else",
    "except",
    "finally",
    "for",
    "from",
    "global",
    "if",
    "import",
    "in",
    "is",
    "lambda",
    "nonlocal",
    "not",
    "or",
    "pass",
    "raise",
    "return",
    "try",
    "while",
    "with",
    "yield",
    "exec"
  ]

-- | A string, bytes or f-string literal.
stringLiteral :: Lexer [Leaf]
stringLiteral = do
  start <- getOffset
  prefix <- takeWhileP Nothing (\c -> toLower c `elem` ("rbuft" :: String))
  quote <- choice (map (try . string) ["\"\"\"", "'''", "\"", "'"])
  end <- getOffset
  let lowered = T.toLower prefix
      raw = "r" `T.isInfixOf` lowered
      formatted = "f" `T.isInfixOf` lowered || "t" `T.isInfixOf` lowered
  if T.length prefix > 3 then fail "not a string prefix" else pure ()
  body <- content quote raw formatted
  closeStart <- getOffset
  _ <- string quote
  closeEnd <- getOffset
  pure ([Leaf Symbol (prefix <> quote) Nothing start end] ++ body ++ [Leaf Symbol quote Nothing closeStart closeEnd])

-- | One piece of a literal's body: text, or a leaf of its own.
data Item = Chunk Int Text | Special Leaf | Interpolated [Leaf]

-- | A literal's body up to its closing quote, as the grammar's leaves.
content :: Text -> Bool -> Bool -> Lexer [Leaf]
content quote raw formatted = settle <$> many item
  where
    item =
      choice
        [ try (Special <$> escapeSequence) <* guardRaw,
          Interpolated <$> interpolation,
          bodyChar
        ]
    guardRaw = if raw then fail "raw" else pure ()
    bodyChar = do
      start <- getOffset
      notFollowedBy (string quote)
      c <- anySingle
      if c == '\n' && T.length quote == 1 then fail "unterminated string" else pure ()
      -- A raw string's backslash escapes its quote without ending it.
      extra <-
        if raw && c == '\\'
          then option "" (T.singleton <$> anySingle)
          else pure ""
      pure (Chunk start (T.cons c extra))
    escapeSequence
      | raw = empty
      | otherwise =
          (if formatted then (plain (string "{{") <|> plain (string "}}")) <|> backslash else backslash)
    backslash = do
      start <- getOffset
      _ <- char '\\'
      known <- optional (try escaped)
      end <- getOffset
      pure (maybe (Leaf Word "\\" Nothing start end) (\text -> Leaf Literal (T.cons '\\' text) Nothing start end) known)
    escaped =
      choice
        [ T.singleton <$> satisfy (`elem` ("\n\\'\"abfnrtv" :: String)),
          T.pack <$> ((:) <$> char 'x' <*> count 2 (satisfy isHexDigit)),
          T.pack <$> ((:) <$> char 'u' <*> count 4 (satisfy isHexDigit)),
          T.pack <$> ((:) <$> char 'U' <*> count 8 (satisfy isHexDigit)),
          (\body -> "N{" <> body <> "}") <$> (string "N{" *> takeWhileP Nothing (/= '}') <* char '}'),
          T.pack <$> (count' 1 3 (satisfy isOctDigit))
        ]
    interpolation
      | formatted = do
          open <- leafAt Literal (const Nothing) (string "{")
          code <- expression
          debug <- optional (try (leafAt Symbol (const Nothing) (string "=") <* lookAhead (satisfy (`elem` ("}!:" :: String)))) <* skipSpaces)
          conversion <- optional (plain (T.cons <$> char '!' <*> (T.singleton <$> satisfy isAlpha)))
          spec <- option [] formatSpec
          close <- leafAt Literal (const Nothing) (string "}")
          pure ([open] ++ code ++ maybe [] pure debug ++ maybe [] pure conversion ++ spec ++ [close])
      | otherwise = empty
    formatSpec = do
      colon <- symbol (string ":")
      inner <- many (Just <$> interpolation <|> (Nothing <$ satisfy (\c -> c /= '}' && c /= '{')))
      pure (colon : concat (mapMaybe id inner))
    skipSpaces = space
    -- The code of an interpolation, up to its end at bracket depth zero.
    expression = skipSpaces *> go (0 :: Int)
      where
        go depth = do
          next <- lookAhead (optional anySingle)
          after <- lookAhead (optional (anySingle *> anySingle))
          case next of
            Nothing -> pure []
            Just c
              | depth == 0 && c == '}' -> pure []
              | depth == 0 && c == '!' && after /= Just '=' -> pure []
              | depth == 0 && c == ':' && after /= Just '=' -> pure []
              | depth == 0 && c == '=' && fmap (`elem` ("}!:" :: String)) (afterEquals after) == Just True -> pure []
              | otherwise -> do
                  leaves <- pyToken
                  skipSpaces
                  let depth' = depth + sum [delta (leafText l) | l <- leaves, leafKind l == Symbol]
                  (leaves ++) <$> go depth'
        afterEquals = id
        delta t
          | t `elem` ["(", "[", "{"] = 1
          | t `elem` [")", "]", "}"] = -1
          | otherwise = 0
    -- Text between interpolations is one content leaf, unless it holds
    -- escape sequences, which the grammar keeps alone.
    settle items = go [] items
      where
        go run [] = flush run
        go run (Interpolated leaves : rest) = flush run ++ leaves ++ go [] rest
        go run (other : rest) = go (run ++ [other]) rest
        flush [] = []
        flush run
          | any isSpecial run = [leaf | Special leaf <- run]
          | otherwise = case [(start, text) | Chunk start text <- run] of
              [] -> []
              chunks@((start, _) : _) ->
                let text = T.concat (map snd chunks)
                 in [Leaf Literal text Nothing start (start + T.length text)]
        isSpecial (Special _) = True
        isSpecial _ = False

-- | The facts of the leaves: definitions and imports at statement starts.
nodes :: Text -> [Leaf] -> [Node]
nodes source leaves = concatMap statement starts
  where
    table = position source
    total = length leaves
    leafTable = listArray (0, max 0 (total - 1)) leaves :: Array Int Leaf
    depthTable = listArray (0, total) depths :: Array Int Int
    -- Bracket depth before each leaf (interpolation braces are literals).
    depths = scanl (\d l -> d + delta l) (0 :: Int) leaves
    delta l
      | leafKind l /= Symbol = 0
      | leafText l `elem` ["(", "[", "{"] = 1
      | leafText l `elem` [")", "]", "}"] = -1
      | otherwise = 0
    leafArray = zip3 [0 :: Int ..] leaves depths
    -- Logical line starts: at depth zero, on a new line.
    lineStarts =
      [ i
      | (i, leaf, depth) <- leafArray,
        depth == 0,
        i == 0 || newLine i leaf
      ]
    newLine i leaf = lineAt table (leafEnd (leafTable ! (i - 1))) < lineAt table (leafStart leaf)
    lineStartSet = IS.fromList lineStarts
    -- The index of the last leaf of the logical line holding a leaf.
    logicalEnd i = maybe (total - 1) (subtract 1) (IS.lookupGT i lineStartSet)
    -- Statement starts: logical lines, after a semicolon, after a
    -- compound header's colon.
    starts =
      lineStarts
        ++ [ i + 1
           | (i, leaf, depth) <- leafArray,
             depth == 0,
             leafKind leaf == Symbol,
             leafText leaf == ";" || (leafText leaf == ":" && headerColon i),
             i + 1 < total,
             not (IS.member (i + 1) lineStartSet)
           ]
    at i
      | i >= 0 && i < total = leafTable ! i
      | otherwise = Leaf Word "" Nothing 0 0
    depthAt i
      | i >= 0 && i <= total = depthTable ! i
      | otherwise = 0
    lineOf i = maybe 0 id (IS.lookupLE i lineStartSet)
    -- The first colon at depth zero of a compound statement's line.
    headerColon i =
      let begin = lineOf i
       in leafText (at begin) `elem` compound
            && null [j | j <- [begin .. i - 1], depthAt j == 0, leafText (at j) == ":", leafKind (at j) == Symbol]
    compound = ["if", "elif", "else", "for", "while", "try", "except", "finally", "with", "def", "class", "async", "match", "case"]
    statement i =
      let first = at i
       in case leafText first of
            "async" | leafText (at (i + 1)) == "def" -> definition i (i + 1)
            "def" -> definition i i
            "class" -> definition i i
            "import" -> importStatement i
            "from" -> fromStatement i
            soft
              | soft `elem` ["match", "case"],
                i `IS.member` lineStartSet,
                leafText (at (i + 1)) `notElem` ["=", ".", ":", ",", ")", "]", "}"],
                not (null [j | j <- [i + 1 .. logicalEnd i], depthAt j == 0, leafText (at j) == ":", leafKind (at j) == Symbol]) ->
                  [Node (leafStart first) (leafEnd first) 0 KeywordFact]
            _ -> []
    statementEnd i = case [j | j <- [i .. logicalEnd i], depthAt j == 0, leafText (at j) == ";", leafKind (at j) == Symbol] of
      j : _ -> j - 1
      [] -> logicalEnd i
    definition begin keyword =
      let nameLeaf = at (keyword + 1)
          kind = if leafText (at keyword) == "class" then "class_definition" else "function_definition"
          colon = case [j | j <- [keyword + 2 .. logicalEnd begin], depthAt j == 0, leafText (at j) == ":", leafKind (at j) == Symbol] of
            j : _ -> Just j
            [] -> Nothing
          column = columnAt table (leafStart (at (lineOf begin)))
          end = case colon of
            Nothing -> logicalEnd begin
            Just j
              | j < logicalEnd begin -> logicalEnd begin
              | otherwise -> case [s | s <- IS.toAscList (snd (IS.split j lineStartSet)), columnAt table (leafStart (at s)) <= column] of
                  s : _ -> s - 1
                  [] -> total - 1
       in case leafName nameLeaf of
            Just name' -> [declaration (leafStart (at begin)) (leafEnd (at end)) kind name' (kind == "class_definition")]
            Nothing -> []
    -- import a.b, c: the first dotted name.
    importStatement i =
      let dotted = dottedFrom (i + 1)
       in [Node (leafStart (at i)) (leafEnd (at (statementEnd i))) 0 (ImportFact (spanOf dotted)) | not (null dotted)]
    fromStatement i =
      let moduleLeaves = takeWhile (\j -> leafText (at j) /= "import" && j <= statementEnd i) [i + 1 .. total - 1]
       in case moduleLeaves of
            [j] | leafText (at j) == "__future__" -> [Node (leafStart (at j)) (leafEnd (at j)) 0 KeywordFact]
            _ : _ -> [Node (leafStart (at i)) (leafEnd (at (statementEnd i))) 0 (ImportFact (spanOf moduleLeaves))]
            [] -> []
    dottedFrom j
      | leafKind (at j) == Name = j : rest (j + 1)
      | otherwise = []
      where
        rest k
          | leafText (at k) == ".", leafKind (at (k + 1)) == Name = k : (k + 1) : rest (k + 2)
          | otherwise = []
    spanOf [] = ""
    spanOf js@(j : _) = slice source (leafStart (at j)) (leafEnd (at (last js)))
