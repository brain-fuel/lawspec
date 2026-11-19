-- | Clojure declarations, imports and namespace names for authoring
-- advice, read as the Clojure grammar's forms. Every list is a candidate:
-- a defrecord, deftype, defn or defn- list declares its second form (a
-- defrecord or deftype is a model); an ns list names a module; a :require
-- or :use list imports the first symbol of each vector entry (any other
-- entry is an unsupported namespace reference); defmacro, load, load-file,
-- require, use and eval lists are dynamic declarations or references the
-- analysis cannot follow. Comments and discarded forms count among a
-- list's forms, as they do in the grammar. Limits: reader conditionals are
-- read as plain forms (both branches), a regular expression's body is not
-- part of a fingerprint, and macros are not expanded.
-- ref:DEC-authoring-advisories
module LawSpec.Authoring.Languages.Clojure (facts) where

import Control.Monad (void)
import Data.Char (isDigit, isHexDigit, isOctDigit, isSpace)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Void (Void)
import LawSpec.Authoring.Syntax
import Text.Megaparsec
import Text.Megaparsec.Char (char, string)

type Parser = Parsec Void Text

-- | What a form is, as far as the advice reads it.
data Shape = List | Vector | SymbolForm | Comment | OtherForm
  deriving (Eq, Show)

-- | A form: its span, its leaves (none for a comment) and the forms
-- inside it (a collection's named children, or a prefixed form's target).
data Form = Form
  { formShape :: Shape,
    formStart :: Int,
    formEnd :: Int,
    formLeaves :: [Leaf],
    formChildren :: [Form]
  }

facts :: Text -> Facts
facts source = case runParser (elements <* eof) "" source of
  Left bundle -> failed ("Native syntax could not be read: " <> T.pack (problem bundle))
  Right forms -> assemble source (concatMap formLeaves forms) (concatMap (nodes source) forms)
  where
    problem bundle = case foldr (:) [] (bundleErrors bundle) of
      e : _ -> "unreadable form at line " ++ show (lineAt (position source) (errorOffset e))
      [] -> "unreadable form"

-- | The facts of a current and of every list inside it.
nodes :: Text -> Form -> [Node]
nodes source current =
  [ node
  | formShape current == List,
    node <- listFacts source current
  ]
    ++ concatMap (nodes source) (formChildren current)

listFacts :: Text -> Form -> [Node]
listFacts source current =
  modules ++ imports ++ dynamic ++ declared
  where
    children = formChildren current
    text = formText source
    at = Node (formStart current) (formEnd current) 0
    headText = text <$> nth 0
    nth i = case drop i children of
      child : _ -> Just child
      [] -> Nothing
    modules = [at (ModuleFact (text second)) | headText == Just "ns", Just second <- [nth 1]]
    imports
      | headText `elem` [Just ":require", Just ":use"] = map entry (drop 1 children)
      | otherwise = []
    entry child = case (formShape child, formChildren child) of
      (Vector, first : _) | formShape first == SymbolForm -> at (ImportFact (text first))
      _ -> at (LimitFact "Unsupported Clojure namespace reference")
    dynamic =
      [ at (LimitFact ("Dynamic Clojure declaration or reference: " <> h))
      | Just h <- [headText],
        h `elem` ["defmacro", "load", "load-file", "require", "use", "eval"]
      ]
    declared =
      [ at (DeclarationFact "list_lit" (text second) (h `elem` ["defrecord", "deftype"]) [])
      | Just h <- [headText],
        h `elem` ["defrecord", "deftype", "defn", "defn-"],
        Just second <- [nth 1]
      ]

formText :: Text -> Form -> Text
formText source current = slice source (formStart current) (formEnd current)

-- | Forms and comments up to a closing bracket or the end.
elements :: Parser [Form]
elements = skipSpace *> many (element <* skipSpace)

skipSpace :: Parser ()
skipSpace = void (takeWhileP Nothing (\c -> isSpace c || c == ','))

element :: Parser Form
element = comment <|> readForm

comment :: Parser Form
comment = do
  start <- getOffset
  void (string ";" <|> try (string "#!"))
  void (takeWhileP Nothing (/= '\n'))
  end <- getOffset
  pure (Form Comment start end [] [])

-- | One form, with any reader prefix.
readForm :: Parser Form
readForm =
  choice
    [ collection "(" ")" List,
      collection "[" "]" Vector,
      collection "{" "}" OtherForm,
      prefixed "#_" OtherForm,
      metadata,
      prefixed "~@" OtherForm,
      prefixed "#'" OtherForm,
      prefixed "#^" OtherForm,
      marked "'",
      marked "`",
      marked "~",
      marked "@",
      dispatch,
      stringForm,
      character,
      keyword,
      atomic
    ]
  where
    marked marker = prefixed marker OtherForm

-- | A prefix and the form it applies to.
prefixed :: Text -> Shape -> Parser Form
prefixed marker shape = do
  start <- getOffset
  leaf <- symbol (try (string marker))
  skipSpace
  target <- readForm
  pure (Form shape start (formEnd target) (leaf : formLeaves target) [target])

-- | Metadata belongs to the form after it, which keeps its shape.
metadata :: Parser Form
metadata = do
  start <- getOffset
  marker <- symbol (string "^")
  skipSpace
  meta <- readForm
  skipSpace
  target <- readForm
  let children = if formShape target == SymbolForm then [] else meta : formChildren target
  pure (Form (formShape target) start (formEnd target) (marker : formLeaves meta ++ formLeaves target) children)

collection :: Text -> Text -> Shape -> Parser Form
collection open close shape = do
  start <- getOffset
  first <- symbol (string open)
  inner <- elements
  final <- symbol (string close)
  pure (Form shape start (leafEnd final) (first : concatMap formLeaves inner ++ [final]) inner)

-- | Forms after #: sets, anonymous functions, regular expressions,
-- reader conditionals, namespaced maps, symbolic values and tags.
dispatch :: Parser Form
dispatch = do
  start <- getOffset
  choice
    [ try (string "#?@" <|> string "#?") >>= \m -> conditional start m,
      try (lookAhead (string "#\"")) *> regex start,
      do
        marker <- symbol (try (string "##"))
        target <- readForm
        pure (Form OtherForm start (formEnd target) (marker : formLeaves target) [target]),
      do
        marker <- symbol (string "#")
        target <- readForm
        pure (Form OtherForm start (formEnd target) (marker : formLeaves target) (formChildren target))
    ]
  where
    conditional start marker = do
      open <- symbol (string "(")
      inner <- elements
      close <- symbol (string ")")
      let leaf = Leaf Symbol marker Nothing start (start + T.length marker)
      pure (Form OtherForm start (leafEnd close) (leaf : open : concatMap formLeaves inner ++ [close]) inner)
    -- The grammar keeps only the marker of a regular expression as a leaf.
    regex start = do
      marker <- symbol (string "#")
      void (char '"')
      void (many (void (char '\\' *> anySingle) <|> void (satisfy (/= '"'))))
      end <- char '"' *> getOffset
      pure (Form OtherForm start end [marker] [])

stringForm :: Parser Form
stringForm = do
  leaf <- plain $ do
    void (char '"')
    body <- many ((\c -> T.pack ['\\', c]) <$> (char '\\' *> anySingle) <|> T.singleton <$> satisfy (/= '"'))
    void (char '"')
    pure ("\"" <> T.concat body <> "\"")
  pure (Form OtherForm (leafStart leaf) (leafEnd leaf) [leaf] [])

character :: Parser Form
character = do
  leaf <- plain $ do
    void (char '\\')
    body <-
      choice
        [ try (string "newline" <|> string "space" <|> string "tab" <|> string "formfeed" <|> string "backspace" <|> string "return"),
          try (T.cons <$> char 'u' <*> (T.pack <$> count 4 (satisfy isHexDigit))),
          try (T.cons <$> char 'o' <*> (T.pack <$> some (satisfy isOctDigit))),
          T.singleton <$> anySingle
        ]
    pure ("\\" <> body)
  pure (Form OtherForm (leafStart leaf) (leafEnd leaf) [leaf] [])

-- | A keyword: its marker, any namespace and its name.
keyword :: Parser Form
keyword = do
  start <- getOffset
  marker <- symbol (try (string "::") <|> string ":")
  body <- getOffset >>= \at -> (,) at <$> takeWhileP Nothing symbolCharacter
  let (offset, text) = body
      (namespace, rest) = T.breakOn "/" text
      leaves
        | not (T.null namespace),
          T.length rest > 1 =
            [ Leaf Literal namespace Nothing offset (offset + T.length namespace),
              Leaf Symbol "/" Nothing (offset + T.length namespace) (offset + T.length namespace + 1),
              nameLeaf (T.drop 1 rest) (offset + T.length namespace + 1)
            ]
        | otherwise = [nameLeaf text offset]
  pure (Form OtherForm start (offset + T.length text) (marker : leaves) [])

-- | A number, boolean, nil or symbol.
atomic :: Parser Form
atomic = do
  start <- getOffset
  text <- takeWhile1P Nothing symbolCharacter
  let end = start + T.length text
      numeric = case T.unpack text of
        c : _ | isDigit c -> True
        s : c : _ | s `elem` ("+-" :: String), isDigit c -> True
        _ -> False
      (namespace, rest) = T.breakOn "/" text
      leaves
        | numeric || text `elem` ["true", "false", "nil"] = [Leaf Literal text Nothing start end]
        | not (T.null namespace),
          T.length rest > 1 =
            [ Leaf Literal namespace Nothing start (start + T.length namespace),
              Leaf Symbol "/" Nothing (start + T.length namespace) (start + T.length namespace + 1),
              nameLeaf (T.drop 1 rest) (start + T.length namespace + 1)
            ]
        | otherwise = [nameLeaf text start]
      shape = if numeric || text `elem` ["true", "false", "nil"] then OtherForm else SymbolForm
  pure (Form shape start end leaves [])

-- | A symbol's or keyword's name, an identifier without a trailing dot.
nameLeaf :: Text -> Int -> Leaf
nameLeaf text start = Leaf Name text (Just (if T.isSuffixOf "." text then T.dropEnd 1 text else text)) start (start + T.length text)

symbolCharacter :: Char -> Bool
symbolCharacter c = not (isSpace c) && c `notElem` ("()[]{}\"@~^;`\\," :: String)
