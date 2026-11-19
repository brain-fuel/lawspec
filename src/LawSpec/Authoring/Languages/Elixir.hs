-- | Elixir declarations, references and limits for authoring advice: the
-- calls of the Elixir grammar whose head is defmodule, def or defp (the
-- declarations), alias, import, require or use (module references), and
-- defmacro or defmacrop (a limit: macros need expansion).
--
-- A declaration is named as the grammar's call reads it: a module by its
-- first argument, a function by the target of its head call (@f@ in
-- @def f(x)@, @unquote(name)@ in @def unquote(name)(x)@), and otherwise by
-- the whole first argument (@f(x) when x > 0@). A call runs from its head
-- to the end of its arguments and do ... end block; a statement ends at a
-- line break unless the line ends with, or the next one starts with, a
-- binary operator. Identifiers are names, aliases (@Foo.Bar@), atoms
-- (@:ok@) and sigil names. Limits: macros are not expanded, so a use or a
-- macro's declarations are not seen; a call written as a variable or
-- through apply is not recognised.
-- ref:DEC-authoring-advisories
module LawSpec.Authoring.Languages.Elixir (facts) where

import Control.Monad (void)
import Data.Char (isAlphaNum, isAsciiLower, isAsciiUpper, isDigit, isSpace)
import Data.Text (Text)
import qualified Data.Text as T
import LawSpec.Authoring.Syntax
import Text.Megaparsec
import Text.Megaparsec.Char (char, string)

facts :: Text -> Facts
facts source = case elixirLeaves source of
  Left problem -> unreadable problem
  Right leaves -> case brackets pairs leaves of
    Left problem -> unreadable problem
    Right trees -> assemble source leaves (calls source trees)
  where
    unreadable problem = failed ("Native syntax could not be read: " <> T.pack problem)
    pairs = [("(", ")"), ("[", "]"), ("{", "}"), ("#{", "}"), ("<<", ">>"), ("do", "end"), ("fn", "end")]

-- | The lexer: do, fn and end are brackets (block delimiters), the other
-- reserved words are keywords.
elixirLeaves :: Text -> Either String [Leaf]
elixirLeaves = lexSource (spaces [lineComment "#"]) elixirToken

elixirToken :: Maybe Leaf -> Lexer [Leaf]
elixirToken previous =
  choice
    [ heredoc "\"\"\"",
      heredoc "'''",
      quotedKeyword,
      delimited (string "\"") (string "\"") [escape, interpolation] (\c -> c == '\\' || c == '"' || c == '#'),
      delimited (string "'") (string "'") [escape, interpolation] (\c -> c == '\\' || c == '\'' || c == '#'),
      sigil,
      try quotedAtom,
      (: []) <$> try atom,
      (: []) <$> plain character,
      (: []) <$> plain number,
      (: []) <$> try keyword,
      (: []) <$> aliasName,
      (: []) <$> identifier,
      (: []) <$> symbol (operatorFrom operators <|> (T.singleton <$> anySingle))
    ]
  where
    afterDot = fmap leafText previous == Just "."
    heredoc delimiter = delimited (string delimiter) (string delimiter) [escape, interpolation] (\c -> c == '\\' || c == T.head delimiter || c == '#')
    -- "quoted key": value, as in [{"b c": 2}]: the key's colon is no leaf.
    quotedKeyword = try $ do
      leaves <- delimited (string "\"") (string "\"") [escape, interpolation] (\c -> c == '\\' || c == '"' || c == '#')
      _ <- char ':'
      lookAhead (void (satisfy isSpace))
      pure leaves
    quotedAtom = do
      colon <- symbol (string ":")
      rest <- delimited (string "\"") (string "\"") [escape, interpolation] (\c -> c == '\\' || c == '"' || c == '#')
      pure (colon : rest)
    atom = do
      start <- getOffset
      _ <- char ':'
      body <- identifierBody <|> operatorFrom atomOperators
      end <- getOffset
      let text = ":" <> body
      pure (Leaf Name text (Just text) start end)
    identifierBody = do
      first <- satisfy (\c -> isAsciiLower c || isAsciiUpper c || c == '_')
      rest <- takeWhileP Nothing (\c -> isAlphaNum c || c == '_' || c == '@')
      suffix <- optional (satisfy (\c -> c == '?' || c == '!'))
      pure (T.cons first rest <> maybe "" T.singleton suffix)
    character = do
      _ <- char '?'
      escaped <- (T.cons '\\' . T.singleton <$> (char '\\' *> anySingle)) <|> (T.singleton <$> anySingle)
      pure ("?" <> escaped)
    -- key: value; the grammar's keyword leaf keeps the space after it.
    keyword = do
      start <- getOffset
      body <- identifierBody
      _ <- char ':'
      space' <- satisfy isSpace
      end <- getOffset
      pure (Leaf Word (body <> ":" <> T.singleton space') Nothing start end)
    aliasName = do
      start <- getOffset
      first <- segment
      rest <- many (try (T.cons <$> char '.' <*> segment))
      end <- getOffset
      let text = T.concat (first : rest)
      pure (Leaf Name text (Just text) start end)
    segment = T.cons <$> satisfy isAsciiUpper <*> takeWhileP Nothing (\c -> isAlphaNum c || c == '_')
    identifier = do
      start <- getOffset
      text <- identifierBody
      end <- getOffset
      let kind
            | afterDot = Name
            | text `elem` ["do", "end", "fn"] = Symbol
            | text `elem` reserved = Word
            | otherwise = Name
      pure (Leaf kind text (if kind == Name then Just text else Nothing) start end)
    sigil = try $ do
      tilde <- symbol (string "~")
      nameStart <- getOffset
      sigilName <- takeWhile1P Nothing (\c -> isAsciiUpper c || isDigit c) <|> (T.singleton <$> satisfy isAsciiLower)
      nameEnd <- getOffset
      let raw = maybe False (isAsciiUpper . fst) (T.uncons sigilName)
          specials = if raw then [] else [escape, interpolation]
          stop close c = c == '\\' || c == close || (not raw && c == '#')
          body (open, close) =
            delimited (string open) (string close) (if raw then [rawEscape close] else specials) (stop (T.head close))
      inner <-
        choice
          [ body ("\"\"\"", "\"\"\""),
            body ("'''", "'''"),
            choice [body pair | pair <- [("/", "/"), ("|", "|"), ("\"", "\""), ("'", "'"), ("(", ")"), ("[", "]"), ("{", "}"), ("<", ">")]]
          ]
      modifiers <- optional (plain (takeWhile1P Nothing isAlphaNum))
      pure ([tilde, Leaf Name sigilName (Just sigilName) nameStart nameEnd] ++ inner ++ maybe [] pure modifiers)
    rawEscape close = (: []) <$> plain (T.cons <$> char '\\' <*> (T.singleton <$> satisfy (== T.head close)))
    operators =
      [ "===",
        "!==",
        "==",
        "!=",
        "<=",
        ">=",
        "&&&",
        "&&",
        "|||",
        "||",
        "|>",
        "<>",
        "++",
        "--",
        "...",
        "..",
        "//",
        "\\\\",
        "::",
        "->",
        "<-",
        "=>",
        "=~",
        "<<<",
        ">>>",
        "<<~",
        "~>>",
        "<~>",
        "<~",
        "~>",
        "^^^",
        "**",
        "<<",
        ">>",
        "+++",
        "---"
      ]
    atomOperators = operators ++ ["+", "-", "*", "/", "<", ">", "!", "^", "&", "|", "=", "@", "."]

-- | A number: a radix literal, or digits with an optional fraction (a
-- dot before a digit, so 1..2 and &1.field stay apart) and exponent.
number :: Lexer Text
number = do
  first <- satisfy isDigit
  rest <- takeWhileP Nothing (\c -> isAlphaNum c || c == '_')
  fraction <- optional . try $ do
    _ <- char '.'
    digit <- satisfy isDigit
    more <- takeWhileP Nothing (\c -> isDigit c || c == '_')
    exponent' <- optional . try $ do
      e <- satisfy (`elem` ("eE" :: String))
      sign <- optional (satisfy (`elem` ("+-" :: String)))
      digits <- takeWhile1P Nothing isDigit
      pure (T.cons e (maybe "" T.singleton sign <> digits))
    pure (T.cons '.' (T.cons digit more) <> maybe "" id exponent')
  pure (T.cons first rest <> maybe "" id fraction)

-- | Code between #{ and }, lexed as code.
interpolation :: Lexer [Leaf]
interpolation = do
  open <- symbol (string "#{")
  inner <- code (0 :: Int) Nothing []
  close <- symbol (string "}")
  pure (open : inner ++ [close])
  where
    code depth previous acc = do
      skip
      next <- lookAhead (optional anySingle)
      case next of
        Just '}' | depth == 0 -> pure (reverse acc)
        Nothing -> pure (reverse acc)
        _ -> do
          leaves <- elixirToken previous
          let depth' = depth + length [() | l <- leaves, leafText l `elem` ["{", "#{"]] - length [() | l <- leaves, leafText l == "}"]
          case leaves of
            [] -> fail "empty token"
            _ -> code depth' (Just (last leaves)) (reverse leaves ++ acc)
    skip = spaces [lineComment "#"]

reserved :: [Text]
reserved = ["true", "false", "nil", "when", "and", "or", "not", "in", "catch", "rescue", "after", "else"]

-- | Every call with a head the advice reads, at any depth.
calls :: Text -> [Tree] -> [Node]
calls source = sequenceCalls
  where
    sequenceCalls trees = concat (zipWith3 at (Nothing : map Just trees) trees (drop 1 (tailsOf trees)))
    tailsOf xs =
      xs : case xs of
        [] -> []
        _ : rest -> tailsOf rest
    at previous tree rest = case tree of
      Group _ inner _ -> sequenceCalls inner
      Atom head'
        | leafKind head' == Name,
          leafText head' `elem` heads,
          maybe True (\p -> not (any (`isAtom` p) [".", "&", "@"])) previous,
          Just found <- callArguments head' rest ->
            callNode head' found
      _ -> []
    callNode head' (arguments, parentheses, block) =
      let end = maybe (maybe (maybe (leafEnd head') treeEnd (lastOf arguments)) treeEnd parentheses) treeEnd block
          start = leafStart head'
          first = takeWhile (not . isAtom ",") arguments
          node = Node start end 0
          headText = leafText head'
       in case headText of
            _
              | headText `elem` ["defmodule", "def", "defp"],
                not (null first) ->
                  [node (DeclarationFact "call" (declaredName first) (headText == "defmodule") [])]
              | headText `elem` ["alias", "import", "require", "use"],
                not (null first) ->
                  ( case first of
                      [Atom module'] | isAlias module' -> [node (ImportFact (leafText module'))]
                      _ -> [node (LimitFact ("Unsupported Elixir " <> headText <> " reference"))]
                  )
                    ++ [node (LimitFact "Elixir use may introduce declarations through macros") | headText == "use"]
              | headText `elem` ["defmacro", "defmacrop"] ->
                  [node (LimitFact "Elixir macro declaration requires expansion")]
            _ -> []
    -- A call's target names it; anything else (an operator such as
    -- when, an alias, a name) is named by its text.
    declaredName first = case reverse first of
      Group open _ _ : target@(final : _)
        | leafText open == "(",
          leafStart open == treeEnd final,
          not (any operator target) ->
            spanText (reverse target)
      _ -> spanText first
    operator (Atom leaf) = leafText leaf `elem` binary && leafText leaf /= "."
    operator _ = False
    spanText trees = case (trees, lastOf trees) of
      (first : _, Just final) -> slice source (treeStart first) (treeEnd final)
      _ -> ""
    isAlias leaf = maybe False (isAsciiUpper . fst) (T.uncons (leafText leaf)) && leafKind leaf == Name
    lastOf [] = Nothing
    lastOf xs = Just (last xs)
    heads = ["defmodule", "def", "defp", "alias", "import", "require", "use", "defmacro", "defmacrop"]
    -- The arguments after a head, and its do ... end block: a group
    -- right after it, or the rest of its statement on the same line.
    callArguments head' rest = case rest of
      Group open inner close : more
        | leafText open == "(",
          leafStart open == leafEnd head' ->
            Just (inner, Just (Group open inner close), doBlock more)
      Group open inner close : _
        | leafText open == "do" -> Just ([], Nothing, Just (Group open inner close))
      next : _
        | startsArgument next,
          not (newlineBetween (leafEnd head') (treeStart next)) ->
            let statement = statementOf head' rest
             in Just $ case reverse statement of
                  group@(Group open _ _) : before | leafText open == "do" -> (reverse before, Nothing, Just group)
                  _ -> (statement, Nothing, Nothing)
      _ -> Nothing
    doBlock (group@(Group open _ _) : _) | leafText open == "do" = Just group
    doBlock _ = Nothing
    newlineBetween from to = T.any (== '\n') (slice source from to)
    startsArgument tree = case tree of
      Group open _ _ -> leafText open `elem` ["[", "{", "<<", "fn", "(", "#{"]
      Atom leaf -> case leafKind leaf of
        Name -> True
        Literal -> True
        Word -> leafText leaf `elem` ["true", "false", "nil", "not"] || ":" `T.isSuffixOf` T.stripEnd (leafText leaf)
        Symbol -> leafText leaf `elem` ["%", "@", "&", "^", "\"", "'", "\"\"\"", "'''", "~", ":", "!"]
    -- The trees of a statement after its head: up to a line break that
    -- does not continue it, a semicolon or a stab arrow.
    statementOf head' = go (Atom head')
      where
        go _ [] = []
        go previous (tree : more)
          | isAtom ";" tree || isAtom "->" tree = []
          | any (`isAtom` tree) ["else", "rescue", "catch", "after"] = []
          | newlineBetween (treeEnd previous) (treeStart tree),
            not (continues previous),
            not (leads tree) =
              []
          | otherwise = tree : go tree more
    continues (Atom leaf) =
      leafText leaf `elem` binary
        || leafText leaf `elem` [",", "&", "@", "^", "!", "not", ".", "%"]
        || (leafKind leaf == Word && ":" `T.isSuffixOf` T.stripEnd (leafText leaf))
    continues _ = False
    leads (Atom leaf) = leafText leaf `elem` binary && leafText leaf `notElem` ["+", "-"]
    leads _ = False
    binary =
      [ "=",
        "|>",
        "+",
        "-",
        "*",
        "/",
        "++",
        "--",
        "<>",
        "==",
        "!=",
        "===",
        "!==",
        "<",
        ">",
        "<=",
        ">=",
        "&&",
        "||",
        "and",
        "or",
        "in",
        "when",
        "::",
        "|",
        "=~",
        "<-",
        "\\\\",
        "..",
        "//",
        "<<<",
        ">>>",
        "~>",
        "<~",
        "~>>",
        "<<~",
        "<~>",
        "|||",
        "&&&",
        "^^^",
        "**",
        "=>",
        "."
      ]
