-- | Gleam declarations and imports for authoring advice: the top-level
-- type definitions, type aliases and named functions of the Gleam grammar,
-- and each import's module path. A type's name is its head with its
-- parameters (@Box(a)@), as the grammar's type_name node reads.
--
-- Names follow the grammar's leaves: lower-case words after a dot or
-- before a colon in an argument list are labels, lower-case words in a
-- type are type variables, and an import's module path contributes only
-- its slashes; none of them are identifiers. Limits: the declarations
-- are found at the top level only (Gleam has no nested named functions or
-- types); bit-array options are recognised by their keyword spelling.
-- ref:DEC-authoring-advisories
module LawSpec.Authoring.Languages.Gleam (facts) where

import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import qualified Data.Set as S
import Data.Text (Text)
import qualified Data.Text as T
import LawSpec.Authoring.Syntax
import Text.Megaparsec
import Text.Megaparsec.Char (string)

facts :: Text -> Facts
facts source = case gleamLeaves source of
  Left problem -> unreadable problem
  Right raw ->
    let (leaves, imports) = dropModulePaths source raw
     in case brackets [("(", ")"), ("[", "]"), ("{", "}")] leaves of
          Left problem -> unreadable problem
          Right trees ->
            let (nodes, plainWords) = items source trees
                cleared = S.fromList plainWords
                named = [if S.member (leafStart l) cleared then l {leafName = Nothing} else l | l <- leaves]
             in assemble source named (nodes ++ imports)
  where
    unreadable problem = failed ("Native syntax could not be read: " <> T.pack problem)

gleamLeaves :: Text -> Either String [Leaf]
gleamLeaves = lexSource (spaces [lineComment "//"]) step
  where
    step _ =
      choice
        [ delimited (string "\"") (string "\"") [escape] (\c -> c == '\\' || c == '"'),
          (: []) <$> plain numberLike,
          (: []) <$> identifier,
          (: []) <$> symbol (operatorFrom operators <|> (T.singleton <$> anySingle))
        ]
    identifier = do
      start <- getOffset
      text <- identifierWith (\c -> isAsciiLower c || isAsciiUpper c || c == '_') (\c -> isAsciiLower c || isAsciiUpper c || isDigit c || c == '_')
      end <- getOffset
      let keyword = text `elem` keywords || "_" `T.isPrefixOf` text
      pure (Leaf (if keyword then Word else Name) text (if keyword then Nothing else Just text) start end)
    operators = ["->", "<-", "|>", "<>", "..", "==", "!=", "<=.", ">=.", "<=", ">=", "<.", ">.", "+.", "-.", "*.", "/.", "&&", "||", "<<", ">>"]

keywords :: [Text]
keywords = ["as", "assert", "auto", "case", "const", "delegate", "derive", "echo", "else", "fn", "if", "implement", "import", "let", "macro", "opaque", "panic", "pub", "test", "todo", "type", "use"]

-- | An import's module path is one grammar node whose only leaves are its
-- slashes: the path's words are no leaves at all. Each import's module is
-- an import fact.
dropModulePaths :: Text -> [Leaf] -> ([Leaf], [Node])
dropModulePaths source = go
  where
    go (leaf : first : rest)
      | leafText leaf == "import",
        leafKind first == Name =
          let (slashes, end, rest') = path (leafEnd first) rest
              (leaves, nodes) = go rest'
           in (leaf : slashes ++ leaves, Node (leafStart leaf) end 0 (ImportFact (slice source (leafStart first) end)) : nodes)
    go (leaf : rest) = let (leaves, nodes) = go rest in (leaf : leaves, nodes)
    go [] = ([], [])
    path _ (slash : word' : more)
      | leafText slash == "/",
        leafKind word' == Name =
          let (slashes, end', rest) = path (leafEnd word') more
           in (slash : slashes, end', rest)
    path end more = ([], end, more)

-- | The top-level items: their declarations and imports, and the offsets
-- of the name-like words that are labels or type variables.
items :: Text -> [Tree] -> ([Node], [Int])
items source = foldMap item . split
  where
    split [] = []
    split (tree : rest) =
      let (inside, after) = breakItem tree rest
       in (tree : inside) : split after
    breakItem previous (tree : rest)
      | starts tree, not (any (`isAtom` previous) ["pub", "opaque"]) = ([], tree : rest)
      | otherwise = let (inside, after) = breakItem tree rest in (tree : inside, after)
    breakItem _ [] = ([], [])
    -- An item starts at an attribute, pub, or a keyword not after pub.
    starts tree = any (`isAtom` tree) ["pub", "@", "import", "const"] || isAtom "type" tree || isAtom "fn" tree
    item trees@(first : _) = case dropWhile (\t -> any (`isAtom` t) ["pub", "opaque"]) trees of
      Atom keyword : rest
        | leafText keyword == "import" -> ([], [])
        | leafText keyword == "fn" -> function first trees rest
        | leafText keyword == "type" -> typeItem first trees rest
        | leafText keyword == "const" -> constant rest
      _ -> ([], expression trees)
    item [] = ([], [])
    function first trees rest = case rest of
      Atom name' : Group _ inner _ : after ->
        let (header, body) = break (isGroup "{") after
            end = case body of
              braces : _ -> treeEnd braces
              [] -> treeEnd (last trees)
            labels = parameterWords inner
         in ( [declaration (treeStart first) end "function" (leafText name') False],
              labels ++ typeWords header ++ expression body
            )
      _ -> ([], expression trees)
    typeItem first trees rest = case rest of
      Atom name' : more ->
        let (parameters, after) = case more of
              group@(Group _ _ _) : remaining | isGroup "(" group -> ([group], remaining)
              _ -> ([], more)
            nameEnd = maybe (leafEnd name') treeEnd (lastMaybe parameters)
            nameText = slice source (leafStart name') nameEnd
            parameterWords' = [leafStart l | t <- parameters, l <- treeLeaves t, leafKind l == Name]
         in case after of
              braces@(Group _ inner _) : _
                | isGroup "{" braces ->
                    ([declaration (treeStart first) (treeEnd braces) "type_definition" nameText True], parameterWords' ++ constructors inner)
              Atom eq : aliased
                | leafText eq == "=" ->
                    ([declaration (treeStart first) (treeEnd (last trees)) "type_alias" nameText True], parameterWords' ++ typeWords aliased)
              _ -> ([], parameterWords')
      _ -> ([], [])
    constant rest =
      let (declared, value) = break (isAtom "=") rest
       in ([], typeWords (drop 1 (dropWhile (not . isAtom ":") declared)) ++ expression (drop 1 value))
    lastMaybe [] = Nothing
    lastMaybe xs = Just (last xs)

-- | Data constructors: each argument is a type, labelled or not.
constructors :: [Tree] -> [Int]
constructors = concatMap constructor
  where
    constructor (Group open inner _)
      | leafText open == "(" = concatMap argument (statements (isAtom ",") inner)
    constructor _ = []
    argument (Atom labelled : Atom colon : rest)
      | leafKind labelled == Name,
        leafText colon == ":" =
          leafStart labelled : typeWords rest
    argument trees = typeWords trees

-- | Function parameters: an optional label, a name and an optional type.
parameterWords :: [Tree] -> [Int]
parameterWords = concatMap parameter . statements (isAtom ",")
  where
    parameter trees =
      let (names, typed) = break (isAtom ":") trees
          labels = case names of
            Atom labelled : _ : _ | leafKind labelled == Name -> [leafStart labelled]
            _ -> []
       in labels ++ typeWords (drop 1 typed)

-- | Within a type, lower-case words are type variables, unless they
-- qualify a type (module.Type).
typeWords :: [Tree] -> [Int]
typeWords = go
  where
    go (Atom leaf : next : rest)
      | isAtom "." next = go rest
      | leafKind leaf == Name, isLower leaf = leafStart leaf : go (next : rest)
    go [Atom leaf]
      | leafKind leaf == Name, isLower leaf = [leafStart leaf]
    go (Group _ inner _ : rest) = go inner ++ go rest
    go (_ : rest) = go rest
    go [] = []

isLower :: Leaf -> Bool
isLower leaf = maybe False (isAsciiLower . fst) (T.uncons (leafText leaf))

-- | In expressions: words after a dot and words before a colon in an
-- argument list are labels; annotations and anonymous functions hold
-- types; bit-array options are keywords.
expression :: [Tree] -> [Int]
expression = go False
  where
    go _ [] = []
    go inArguments (Atom dot : Atom leaf : rest)
      | leafText dot == ".",
        leafKind leaf == Name,
        isLower leaf =
          leafStart leaf : go inArguments rest
    go inArguments (Atom leaf : Atom colon : rest)
      | inArguments,
        leafKind leaf == Name,
        isLower leaf,
        leafText colon == ":" =
          leafStart leaf : go inArguments rest
    go inArguments (Atom fn' : parameters@(Group _ inner _) : rest)
      | leafText fn' == "fn",
        isGroup "(" parameters =
          let (header, body) = break (isGroup "{") rest
           in parameterWords inner ++ typeWords header ++ go inArguments body
    go inArguments (Atom keyword : rest)
      | leafText keyword == "let" =
          let (pattern, after) = break (\t -> isAtom "=" t || isAtom ":" t) rest
           in case after of
                Atom colon : typed
                  | leafText colon == ":" ->
                      let (annotation, value) = break (isAtom "=") typed
                       in go False pattern ++ typeWords annotation ++ go inArguments value
                _ -> go False pattern ++ go inArguments after
    go inArguments (Atom open : rest)
      | leafText open == "<<" =
          let (segments, after) = break (isAtom ">>") rest
           in bitArray segments ++ go inArguments (drop 1 after)
    go inArguments (Group open inner _ : rest) =
      go (leafText open == "(") inner ++ go inArguments rest
    go inArguments (_ : rest) = go inArguments rest
    bitArray trees =
      [ leafStart leaf
      | (previous, Atom leaf) <- zip (Nothing : map Just trees) trees,
        maybe False (\p -> isAtom ":" p || isAtom "-" p) previous,
        leafText leaf `elem` options
      ]
        ++ concat [expression [t] | t@(Group _ _ _) <- trees]
    options = ["size", "unit", "int", "float", "bits", "bytes", "bit_array", "bit_string", "utf8", "utf16", "utf32", "utf8_codepoint", "utf16_codepoint", "utf32_codepoint", "signed", "unsigned", "big", "little", "native"]
