-- | Go declarations, imports and package names for authoring advice: the
-- type specs (at any depth), function and method declarations of the Go
-- grammar; each import spec's path, and each import declaration as an
-- unresolved import (as the Tree-sitter extraction read it); the package
-- clause. Statements end at semicolons and where Go inserts them at line
-- ends. Type aliases (type A = B) are not declarations here, as they were
-- not before. Limits: no name resolution; generic type declarations are
-- read by their name only.
-- ref:DEC-authoring-advisories
module LawSpec.Authoring.Languages.Go (facts) where

import Data.Char (isAlpha, isAlphaNum)
import Data.Text (Text)
import qualified Data.Text as T
import LawSpec.Authoring.Syntax
import Text.Megaparsec
import Text.Megaparsec.Char (char, string)

facts :: Text -> Facts
facts source = case goLeaves source of
  Left problem -> unreadable problem
  Right leaves -> case brackets [("(", ")"), ("[", "]"), ("{", "}")] leaves of
    Left problem -> unreadable problem
    Right trees -> assemble source leaves (topLevel source table trees ++ nils False trees)
  where
    unreadable problem = failed ("Native syntax could not be read: " <> T.pack problem)
    table = position source

goLeaves :: Text -> Either String [Leaf]
goLeaves = lexSource (spaces [lineComment "//", blockComment False "/*" "*/"]) step
  where
    step _ =
      choice
        [ delimited (string "\"") (string "\"") [escape] (\c -> c == '\\' || c == '"'),
          delimited (string "`") (string "`") [] (== '`'),
          (: []) <$> plain rune,
          (: []) <$> plain numberLike,
          (: []) <$> identifier,
          (: []) <$> symbol (operatorFrom operators <|> (T.singleton <$> anySingle))
        ]
    identifier = do
      start <- getOffset
      text <- identifierWith (\c -> isAlpha c || c == '_') (\c -> isAlphaNum c || c == '_')
      end <- getOffset
      let keyword = text `elem` reserved
      pure (Leaf (if keyword then Word else Name) text (if keyword then Nothing else Just text) start end)
    rune = do
      _ <- char '\''
      first <- (T.cons '\\' . T.singleton <$> (char '\\' *> anySingle)) <|> (T.singleton <$> anySingle)
      rest <- takeWhileP Nothing (/= '\'')
      _ <- char '\''
      pure ("'" <> first <> rest <> "'")
    operators = [":=", "...", "<-", "&^=", "&^", "&&", "||", "==", "!=", "<=", ">=", "<<=", ">>=", "<<", ">>", "++", "--", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^="]

reserved :: [Text]
reserved =
  [ "break",
    "case",
    "chan",
    "const",
    "continue",
    "default",
    "defer",
    "else",
    "fallthrough",
    "for",
    "func",
    "go",
    "goto",
    "if",
    "import",
    "interface",
    "map",
    "package",
    "range",
    "return",
    "select",
    "struct",
    "switch",
    "type",
    "var",
    "true",
    "false",
    "iota"
  ]

-- | Split a sequence into statements at semicolons and at line ends where
-- Go inserts a semicolon.
goStatements :: Position -> [Tree] -> [[Tree]]
goStatements table = filter (not . null) . go []
  where
    go acc [] = [reverse acc]
    go acc (tree : rest)
      | isAtom ";" tree = reverse acc : go [] rest
      | otherwise = case rest of
          next : _
            | lineAt table (treeEnd tree) < lineAt table (treeStart next),
              ends tree ->
                reverse (tree : acc) : go [] rest
          _ -> go (tree : acc) rest
    ends (Group _ _ _) = True
    ends (Atom leaf) =
      leafKind leaf `elem` [Name, Literal]
        || leafText leaf `elem` ["break", "continue", "fallthrough", "return", "++", "--", "true", "false", "nil", "iota", "\"", "`"]

topLevel :: Text -> Position -> [Tree] -> [Node]
topLevel source table = concatMap statement . goStatements table
  where
    statement trees@(first : rest)
      | isAtom "package" first,
        Atom name' : _ <- rest =
          [Node (treeStart first) (leafEnd name') 0 (ModuleFact (leafText name'))]
      | isAtom "import" first =
          Node (treeStart first) (endOf trees) 0 (LimitFact ("Unresolved import syntax at line " <> T.pack (show (lineAt table (treeStart first)))))
            : case rest of
              [Group open inner _] | leafText open == "(" -> concatMap importSpec (goStatements table inner)
              _ -> importSpec rest
      | isAtom "func" first = case rest of
          Atom name' : _
            | Just n <- leafName name' ->
                declaration (treeStart first) (endOf trees) "function_declaration" n False : code source table rest
          receiver@(Group _ _ _) : Atom name' : _
            | isGroup "(" receiver,
              Just n <- leafName name' ->
                declaration (treeStart first) (endOf trees) "method_declaration" n False : code source table rest
          _ -> code source table trees
    statement trees = code source table trees
    importSpec trees = case [t | t <- trees, isAtom "\"" t || isAtom "`" t] of
      open : _ ->
        let quoted = dropWhile (not . (== treeStart open) . treeStart) trees
            text = slice source (treeStart open) (endOf quoted)
         in [Node (maybe 0 treeStart (firstOf trees)) (endOf trees) 0 (ImportFact (strip text))]
      [] -> []
    strip text =
      let t1 = if T.take 1 text `elem` ["\"", "'"] then T.drop 1 text else text
       in if T.takeEnd 1 t1 `elem` ["\"", "'"] then T.dropEnd 1 t1 else t1

firstOf :: [a] -> Maybe a
firstOf (x : _) = Just x
firstOf [] = Nothing

endOf :: [Tree] -> Int
endOf [] = 0
endOf trees = treeEnd (last trees)

-- | Type specs anywhere in code (local types), and in grouped type
-- declarations.
code :: Text -> Position -> [Tree] -> [Node]
code _ table = go
  where
    go [] = []
    go (tree : rest)
      | isAtom "type" tree = case rest of
          [Group open inner _] | leafText open == "(" -> concatMap spec (goStatements table inner)
          Group open inner _ : more | leafText open == "(" -> concatMap spec (goStatements table inner) ++ go more
          _ ->
            let (this, more) = statementOf rest
             in spec this ++ go more
      | otherwise = nested tree ++ go rest
    nested (Group _ inner _) = concatMap (go) (goStatements table inner)
    nested _ = []
    -- The rest of the current statement.
    statementOf trees = case goStatements table trees of
      this : _ -> (this, drop (length this) (dropSemicolon trees this))
      [] -> ([], [])
    dropSemicolon trees _ = trees
    spec trees@(Atom name' : afterName)
      | Just n <- leafName name',
        not (alias afterName) =
          declaration (leafStart name') (endOf trees) "type_spec" n True : concatMap nested afterName
    spec trees = concatMap nested trees
    alias (Atom eq : _) = leafText eq == "="
    alias (Group open _ _ : Atom eq : _) = leafText open == "[" && leafText eq == "="
    alias _ = False

-- | nil is a keyword, except as a type in a type switch's case list, where
-- the grammar reads it as a type name.
nils :: Bool -> [Tree] -> [Node]
nils typeCases = go False
  where
    go _ [] = []
    go inCase (tree : rest) = case tree of
      Atom leaf
        | leafText leaf == "nil",
          not (typeCases && inCase) ->
            Node (leafStart leaf) (leafEnd leaf) 0 KeywordFact : go inCase rest
        | leafText leaf == "case" -> go True rest
        | leafText leaf == ":" -> go False rest
        | leafText leaf == "switch" ->
            let (header, after) = break (isGroup "{") rest
             in case after of
                  Group _ inner _ : more ->
                    concatMap (nested False) header ++ nils (any typeSwitch header) inner ++ go False more
                  [] -> concatMap (nested False) header
                  _ -> go False after
        | otherwise -> go inCase rest
      Group _ inner _ -> nils False inner ++ go inCase rest
    nested flag (Group _ inner _) = nils flag inner
    nested _ (Atom leaf) = [Node (leafStart leaf) (leafEnd leaf) 0 KeywordFact | leafText leaf == "nil"]
    typeSwitch (Group open [Atom t] _) = leafText open == "(" && leafText t == "type"
    typeSwitch _ = False
