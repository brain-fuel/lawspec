-- | The shared machinery of the native fact extractors that authoring advice
-- reads (ref:DEC-authoring-advisories). Each language's extractor lexes a
-- source into leaves (comments dropped), groups them by brackets, and
-- recognises only the declarations, imports, module names and unsupported
-- constructs the advice rules need; everything else is skipped. The facts
-- keep the names, kinds and traversal order of the Tree-sitter grammars the
-- advice used before (hand-written expectations in test/AuthoringNativeSpec.hs
-- check them), so the advice reads the same. Extraction is bounded syntax
-- analysis, not native compilation, name resolution or type checking.
module LawSpec.Authoring.Syntax
  ( -- * Leaves
    Leaf (..),
    Kind (..),
    Lexer,
    lexSource,
    leafAt,
    name,
    word,
    symbol,
    plain,

    -- * Lexing helpers
    lineComment,
    blockComment,
    spaces,
    delimited,
    escape,
    identifierWith,
    numberLike,
    operatorFrom,

    -- * Bracket trees
    Tree (..),
    brackets,
    treeStart,
    treeEnd,
    treeLeaves,
    treeText,
    atomText,
    isAtom,
    isGroup,
    groupOpen,
    statements,

    -- * Facts
    Node (..),
    Fact (..),
    declaration,
    Declaration (..),
    Facts (..),
    Source (..),
    assemble,
    failed,
    Position,
    position,
    lineAt,
    columnAt,
    slice,
  )
where

import Control.Monad (void)
import Data.Array (Array, bounds, listArray, (!))
import Data.Char (isAlphaNum, isDigit, isHexDigit, isSpace)
import Data.List (sortBy)
import Data.Ord (Down (..), comparing)
import qualified Data.Set as S
import Data.Text (Text)
import qualified Data.Text as T
import Data.Void (Void)
import LawSpec.Digest (digestHex, digestString)
import Text.Megaparsec
import Text.Megaparsec.Char (char, string)

-- | What a leaf is, as far as the advice reads it: a name counts among a
-- declaration's identifiers, a word is any other keyword-like token, and
-- text is a piece of a literal.
data Kind = Name | Word | Symbol | Literal
  deriving (Eq, Show)

-- | One token of the source, between two character offsets. 'leafName' is
-- the identifier it contributes (atoms lose their quotes), when it is one.
data Leaf = Leaf
  { leafKind :: !Kind,
    leafText :: !Text,
    leafName :: !(Maybe Text),
    leafStart :: !Int,
    leafEnd :: !Int
  }
  deriving (Eq, Show)

type Lexer = Parsec Void Text

-- | A leaf over what the parser consumes.
leafAt :: Kind -> (Text -> Maybe Text) -> Lexer Text -> Lexer Leaf
leafAt kind naming parser = do
  start <- getOffset
  text <- parser
  end <- getOffset
  pure (Leaf kind text (naming text) start end)

name, word, symbol, plain :: Lexer Text -> Lexer Leaf
name = leafAt Name Just
word = leafAt Word (const Nothing)
symbol = leafAt Symbol (const Nothing)
plain = leafAt Literal (const Nothing)

-- | Run a lexer over a whole source: the language's step is given the
-- previous leaf (for the few contexts that need it: regular expressions,
-- character literals) and returns the leaves of one token; the space
-- parser skips whitespace and comments.
lexSource :: Lexer () -> (Maybe Leaf -> Lexer [Leaf]) -> Text -> Either String [Leaf]
lexSource space step source = case runParser (space *> go Nothing [] <* eof) "" source of
  Left bundle -> Left (unreadable bundle)
  Right leaves -> Right leaves
  where
    go previous acc = do
      done <- atEnd
      if done
        then pure (reverse acc)
        else do
          leaves <- step previous
          space
          case leaves of
            [] -> fail "unrecognised character"
            _ -> go (Just (last leaves)) (reverse leaves ++ acc)
    unreadable bundle = case foldr (:) [] (bundleErrors bundle) of
      problem : _ -> "unreadable token at line " ++ show (lineAt (position source) (errorOffset problem))
      [] -> "unreadable token"

-- | A comment to the end of the line.
lineComment :: Text -> Lexer ()
lineComment start = void (string start *> takeWhileP Nothing (/= '\n'))

-- | A block comment, nested when the language nests them.
blockComment :: Bool -> Text -> Text -> Lexer ()
blockComment nested open close = void (string open *> body)
  where
    body =
      void (try (string close))
        <|> (if nested then try (void (blockComment True open close)) *> body else empty)
        <|> (anySingle *> body)

-- | Whitespace and the given comments.
spaces :: [Lexer ()] -> Lexer ()
spaces comments = skipMany (void (takeWhile1P Nothing isSpace) <|> choice (map try comments))

-- | A delimited literal: its opening delimiter, the pieces of its body and
-- its closing delimiter, as separate leaves the way the grammars split
-- them. A special piece (an escape sequence, an interpolation) is tried
-- where the body has a character for which the stop predicate holds; any
-- other text is content.
delimited :: Lexer Text -> Lexer Text -> [Lexer [Leaf]] -> (Char -> Bool) -> Lexer [Leaf]
delimited open close specials stop = do
  first <- symbol open
  body <- many (try (notFollowedBy close *> choice specials) <|> ((: []) <$> plain fragment))
  final <- symbol close
  pure ([first] ++ concat body ++ [final])
  where
    fragment = T.concat <$> some piece
    piece =
      takeWhile1P Nothing (not . stop)
        <|> try (notFollowedBy close *> notFollowedBy (choice (map (lookAhead . try) specials)) *> (T.singleton <$> anySingle))

-- | An escape sequence: a backslash and the character after it.
escape :: Lexer [Leaf]
escape = (: []) <$> plain (T.cons <$> char '\\' <*> (T.singleton <$> anySingle))

-- | An identifier from its first and following characters.
identifierWith :: (Char -> Bool) -> (Char -> Bool) -> Lexer Text
identifierWith first rest = T.cons <$> satisfy first <*> takeWhileP Nothing rest

-- | A numeric literal, read loosely: digits, letters, dots between digits,
-- underscores and an exponent sign.
numberLike :: Lexer Text
numberLike = do
  first <- satisfy isDigit
  rest <- many (try signedExponent <|> try dotDigit <|> (T.singleton <$> satisfy (\c -> isAlphaNum c || c == '_')))
  pure (T.concat (T.singleton first : rest))
  where
    signedExponent = do
      e <- satisfy (`elem` ("eEpP" :: String))
      sign <- satisfy (`elem` ("+-" :: String))
      digit <- satisfy isDigit
      pure (T.pack [e, sign, digit])
    dotDigit = do
      void (char '.')
      digit <- satisfy isHexDigit
      pure (T.pack ['.', digit])

-- | The longest operator in the list at this point, else a single symbol
-- character.
operatorFrom :: [Text] -> Lexer Text
operatorFrom operators =
  choice [try (string operator) | operator <- sortBy (comparing (Down . T.length)) operators]

-- | A source grouped by brackets.
data Tree = Atom Leaf | Group Leaf [Tree] Leaf
  deriving (Eq, Show)

-- | Group leaves by the given bracket pairs; an unbalanced bracket fails.
brackets :: [(Text, Text)] -> [Leaf] -> Either String [Tree]
brackets pairs = go []
  where
    go acc [] = Right (reverse acc)
    go acc (leaf : rest)
      | leafKind leaf == Symbol,
        Just close <- lookup (leafText leaf) pairs = do
          (inner, closing, rest') <- group close rest []
          go (Group leaf inner closing : acc) rest'
      | leafKind leaf == Symbol,
        leafText leaf `elem` map snd pairs =
          Left ("unbalanced " ++ T.unpack (leafText leaf) ++ " at offset " ++ show (leafStart leaf))
      | otherwise = go (Atom leaf : acc) rest
    group close [] _ = Left ("unclosed bracket; expected " ++ T.unpack close)
    group close (leaf : rest) acc
      | leafKind leaf == Symbol,
        leafText leaf == close =
          Right (reverse acc, leaf, rest)
      | leafKind leaf == Symbol,
        Just close' <- lookup (leafText leaf) pairs = do
          (inner, closing, rest') <- group close' rest []
          group close rest' (Group leaf inner closing : acc)
      | leafKind leaf == Symbol,
        leafText leaf `elem` map snd pairs =
          Left ("unbalanced " ++ T.unpack (leafText leaf) ++ " at offset " ++ show (leafStart leaf))
      | otherwise = group close rest (Atom leaf : acc)

treeStart, treeEnd :: Tree -> Int
treeStart (Atom leaf) = leafStart leaf
treeStart (Group open _ _) = leafStart open
treeEnd (Atom leaf) = leafEnd leaf
treeEnd (Group _ _ close) = leafEnd close

treeLeaves :: Tree -> [Leaf]
treeLeaves (Atom leaf) = [leaf]
treeLeaves (Group open inner close) = open : concatMap treeLeaves inner ++ [close]

-- | An atom's text; a group has none.
atomText :: Tree -> Maybe Text
atomText (Atom leaf) = Just (leafText leaf)
atomText _ = Nothing

-- | The source text of a tree.
treeText :: Text -> Tree -> Text
treeText source tree = slice source (treeStart tree) (treeEnd tree)

isAtom :: Text -> Tree -> Bool
isAtom text tree = atomText tree == Just text

isGroup :: Text -> Tree -> Bool
isGroup open (Group leaf _ _) = leafText leaf == open
isGroup _ _ = False

groupOpen :: Tree -> Maybe Text
groupOpen (Group leaf _ _) = Just (leafText leaf)
groupOpen _ = Nothing

-- | Split a sequence at separator atoms, dropping the separators and empty
-- statements.
statements :: (Tree -> Bool) -> [Tree] -> [[Tree]]
statements separator = filter (not . null) . go []
  where
    go acc [] = [reverse acc]
    go acc (tree : rest)
      | separator tree = reverse acc : go [] rest
      | otherwise = go (tree : acc) rest

-- | A fact the advice reads, at the span of the syntax node it comes from.
data Node = Node {nodeStart :: !Int, nodeEnd :: !Int, nodeDepth :: !Int, nodeFact :: Fact}
  deriving (Eq, Show)

data Fact
  = DeclarationFact
      { factKind :: Text,
        factName :: Text,
        factModel :: Bool,
        factFields :: [Text]
      }
  | ImportFact Text
  | ModuleFact Text
  | LimitFact Text
  | -- | A word that is a keyword here, though it is a name elsewhere.
    KeywordFact
  deriving (Eq, Show)

-- | A declaration fact at a node's span.
declaration :: Int -> Int -> Text -> Text -> Bool -> Node
declaration start end kind name' model = Node start end 0 (DeclarationFact kind name' model [])

data Declaration = Declaration
  { declarationName :: Text,
    declarationKind :: Text,
    declarationLine :: Int,
    declarationFields :: [Text],
    declarationIdentifiers :: [Text],
    declarationModel :: Bool,
    declarationFingerprint :: String
  }
  deriving (Eq, Show)

-- | authoring.mjs parse's result.
data Facts = Facts
  { factsStatus :: Text,
    factsReason :: Maybe Text,
    factsDeclarations :: [Declaration],
    factsImports :: [Text],
    factsModules :: [Text],
    factsLimits :: [Text],
    factsFingerprint :: String
  }
  deriving (Eq, Show)

-- | A native source by path.
data Source = Source {sourcePath :: FilePath, sourceContent :: Text}
  deriving (Eq, Show)

-- | Line starts, for line and column numbers.
newtype Position = Position (Array Int Int)

position :: Text -> Position
position source =
  let starts = 0 : [i + 1 | (i, c) <- zip [0 ..] (T.unpack source), c == '\n']
   in Position (listArray (0, length starts - 1) starts)

-- | The 1-based line of an offset.
lineAt :: Position -> Int -> Int
lineAt (Position starts) offset = search 0 (snd (bounds starts))
  where
    search low high
      | low >= high = low + 1
      | otherwise =
          let middle = (low + high + 1) `div` 2
           in if starts ! middle <= offset then search middle high else search low (middle - 1)

-- | The 0-based column of an offset.
columnAt :: Position -> Int -> Int
columnAt table@(Position starts) offset = offset - starts ! (lineAt table offset - 1)

slice :: Text -> Int -> Int -> Text
slice source start end = T.take (end - start) (T.drop start source)

-- | An extraction that could not read the source.
failed :: Text -> Facts
failed reason = Facts "incomplete" (Just reason) [] [] [] [] ""

-- | The facts of a source from its leaves and recognised nodes, in the
-- order a Tree-sitter traversal visits them: a node before the nodes
-- inside it, and a later sibling before an earlier one.
assemble :: Text -> [Leaf] -> [Node] -> Facts
assemble source leaves' nodes
  | length leaves > 100000 = failed "Native syntax exceeds the 100000-token analysis limit"
  | otherwise =
      Facts
        { factsStatus = "complete",
          factsReason = Nothing,
          factsDeclarations = [describe node fact | node@Node {nodeFact = fact@DeclarationFact {}} <- ordered],
          factsImports = [text | Node {nodeFact = ImportFact text} <- ordered],
          factsModules = [text | Node {nodeFact = ModuleFact text} <- ordered],
          factsLimits = [text | Node {nodeFact = LimitFact text} <- ordered],
          factsFingerprint = fingerprint Nothing leaves
        }
  where
    keywords = S.fromList [nodeStart node | node@Node {nodeFact = KeywordFact} <- nodes]
    leaves = [if S.member (leafStart leaf) keywords then leaf {leafName = Nothing} else leaf | leaf <- leaves']
    table = position source
    ordered = map snd (sortBy (comparing fst) (zip [order node i | (node, i) <- zip nodes [0 :: Int ..]] nodes))
    order node i = (Down (nodeEnd node), nodeStart node, nodeDepth node, i)
    -- The leaves of a node's span, from the first found by binary search.
    total = length leaves
    array = listArray (0, total - 1) leaves :: Array Int Leaf
    firstFrom offset = search 0 total
      where
        search low high
          | low >= high = low
          | otherwise =
              let middle = (low + high) `div` 2
               in if leafStart (array ! middle) < offset then search (middle + 1) high else search low middle
    within node =
      takeWhile (\l -> leafEnd l <= nodeEnd node) [array ! i | i <- [firstFrom (nodeStart node) .. total - 1]]
    describe node fact =
      let inside = within node
       in Declaration
            { declarationName = factName fact,
              declarationKind = factKind fact,
              declarationLine = lineAt table (nodeStart node),
              declarationFields = factFields fact,
              declarationIdentifiers = [n | Just n <- map leafName inside],
              declarationModel = factModel fact,
              declarationFingerprint = fingerprint (Just (factName fact)) inside
            }
    fingerprint declared inside =
      -- A punctuation leaf keeps its text, as an anonymous Tree-sitter node
      -- keeps its type: operator declarations stay apart.
      digestHex (digestString (show [(leafKind l, if Just (leafText l) == declared && leafKind l /= Symbol then "$declaration" else leafText l) | l <- inside]))
