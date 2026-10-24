-- | One place decides the names generated code uses. Source names are kept,
-- cased the way the target writes them; a keyword is escaped the target's own
-- way; a collision gets _2, _3 in declaration order. Compiler-made values
-- have short names that say what they hold. Core identities never change:
-- these are spellings only. ref:DEC-readable-generated-names
module LawSpec.Naming
  ( Casing(..), NameKind(..), nameWords, cased, casingFor, escapeKeyword, reservedFor
  , nativeIdentifier, Scope, emptyScope, scopeWith, claim, claimAll, uniqueNames
  , testName, exampleTestSuffix, boundaryTestSuffix, displayLabel, localIdentifier, readableDefinitionName, sourceDefinitionName, typeWords
  ) where

import Data.Char (isAlphaNum, isAscii, isDigit, isHexDigit, isLower, isUpper, toLower, toUpper)
import qualified LawSpec.Core as C
import Data.List (intercalate, isPrefixOf, stripPrefix, dropWhileEnd)
import qualified Data.Set as S
import LawSpec.TargetNames (targetKeywords)
import LawSpec.TestNames (lawWords, testIdentifier)

-- | How a target writes a name made of several words.
data Casing = Snake | Camel | Pascal | Kebab | ScreamingSnake deriving (Eq, Show)

-- | What a name names: each kind has its own casing on some targets.
data NameKind = ValueName | FunctionName | TypeName | ConstantName deriving (Eq, Show)

-- | A source name's words, from camelCase, snake_case, kebab-case or a
-- phrase name ("|a phrase|). Non-ASCII letters and digits are dropped, as
-- every target accepts ASCII identifiers.
nameWords :: String -> [String]
nameWords = filter (not . null) . concatMap camelWords . words . map separator . unphrase
  where
    unphrase ('"' : '|' : body) = takeWhile (/= '|') body
    unphrase ('|' : body) = takeWhile (/= '|') body
    unphrase name = name
    separator c = if isAscii c && isAlphaNum c then c else ' '
    -- fooBar, HTTPServer and value2 split as foo bar, http server, value2.
    camelWords w = map (map toLower) (go w)
      where
        go [] = []
        go s@(c : _)
          | isUpper c =
              let (upper, rest) = span isUpper s
              in case rest of
                  (r : _) | isLower r, length upper > 1 -> init upper : go (last upper : rest)
                  _ -> let (lower, rest') = span (not . isUpper) rest in (upper ++ lower) : go rest'
          | otherwise = let (lower, rest) = span (not . isUpper) s in lower : go rest

-- | Words joined in a casing.
cased :: Casing -> [String] -> String
cased casing ws = case (casing, ws) of
  (_, []) -> ""
  (Snake, _) -> intercalate "_" ws
  (ScreamingSnake, _) -> map toUpper (intercalate "_" ws)
  (Kebab, _) -> intercalate "-" ws
  (Camel, w : rest) -> w ++ concatMap capital rest
  (Pascal, _) -> concatMap capital ws
  where
    capital (c : cs) = toUpper c : cs
    capital [] = []

-- | Each target's casing for each kind of name.
casingFor :: String -> NameKind -> Casing
casingFor target kind = case (target, kind) of
  (_, TypeName) -> Pascal
  (t, ConstantName) | t `elem` ["python", "rust", "javascript", "typescript", "java", "groovy", "kotlin", "scala"] -> ScreamingSnake
  (t, _) | t `elem` ["python", "rust", "erlang", "elixir", "gleam", "prolog", "hcl", "yaml", "make"] -> Snake
  ("clojure", _) -> Kebab
  ("csharp", FunctionName) -> Pascal
  ("go", ConstantName) -> Camel
  _ -> Camel

-- | Names a target reserves where generated code declares locals: its
-- keywords and, in Python, the builtins and module aliases generated code
-- uses, so a source binder named list or ls cannot shadow them.
reservedFor :: String -> [String]
reservedFor target = targetKeywords target ++ case target of
  "python" -> words "ls data symbols builtins print len list dict set tuple str int bool bytes float object type id range min max abs all any iter next map filter zip sorted reversed super self cls isinstance callable"
  "javascript" -> words "ls impl data schema symbols fc assert test describe undefined NaN Infinity"
  "typescript" -> words "ls impl data schema symbols fc assert test describe undefined NaN Infinity"
  -- Go: its keywords and predeclared names, the packages generated tests
  -- import, and the names generated Go code gives its own locals.
  "go" -> words "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var" ++
    words "any append bool byte cap clear close complex complex64 complex128 copy delete error false float32 float64 imag int int8 int16 int32 int64 iota len make max min new nil panic print println real recover rune string true uint uint8 uint16 uint32 uint64 uintptr" ++
    words "flag fmt os testing rapid t m symbols seed values code problem err matched matchedItems matchedData results"
  _ -> []

-- | A keyword or reserved name escaped the target's own way: a trailing
-- underscore in Python (PEP 8) and Rust's raw identifiers; elsewhere a
-- trailing underscore.
escapeKeyword :: String -> String -> String
escapeKeyword target name
  | name `notElem` reservedFor target = name
  | target == "rust" && name `notElem` ["self", "Self", "super", "crate"] = "r#" ++ name
  | otherwise = name ++ "_"

-- | A source name as a target identifier of a kind: cased, made to start
-- with a letter, and escaped.
nativeIdentifier :: String -> NameKind -> String -> String
nativeIdentifier target kind source = escapeKeyword target (leading (cased (casingFor target kind) ws))
  where
    ws = case nameWords source of
      [] -> ["value"]
      found -> found
    leading name@(c : _) | isDigit c = (if kind == TypeName then "T" else "v") ++ name
    leading name = name

-- | Names already taken in a scope, compared as the target compares them.
newtype Scope = Scope (S.Set String)

emptyScope :: Scope
emptyScope = Scope S.empty

-- | A scope where some names are already taken (imports, runtime aliases).
scopeWith :: [String] -> Scope
scopeWith = Scope . S.fromList

-- | The first free spelling of a name: itself, then name_2, name_3, ...
claim :: Scope -> String -> (String, Scope)
claim (Scope taken) name = (chosen, Scope (S.insert chosen taken))
  where
    chosen = case [c | c <- name : [name ++ "_" ++ show n | n <- [2 :: Int ..]], c `S.notMember` taken] of
      c : _ -> c
      [] -> name

-- | Names claimed in order.
claimAll :: Scope -> [String] -> ([String], Scope)
claimAll scope [] = ([], scope)
claimAll scope (n : rest) = let (chosen, scope') = claim scope n
                                (others, final) = claimAll scope' rest
                            in (chosen : others, final)

-- | Names made unique in declaration order.
uniqueNames :: [String] -> [String]
uniqueNames = fst . claimAll emptyScope

-- | A law's test name on a target (LawSpec.TestNames).
testName :: String -> String -> String
testName target label = testIdentifier target (lawWords label)

-- | The suffix naming one example's test, after the law's test name and the
-- target's separator: the example's own words, so a failure names the case.
-- Examples with no usable words, or whose words repeat, are numbered from 1.
exampleTestSuffix :: String -> [String] -> [String] -> [String]
exampleTestSuffix target taken names = fst $ claimAll (scopeWith taken)
  [ case lawWords n of
      ["law"] -> "example_" ++ show i
      ws -> joined ws
  | (i, n) <- zip [1 :: Int ..] names ]
  where
    joined ws = case target of
      "python" -> intercalate "_" ws
      _ -> intercalate "_" ws

-- | Boundary cases have no names; they are numbered from 1.
boundaryTestSuffix :: Int -> String
boundaryTestSuffix i = "boundary_" ++ show (i + 1)

-- | A law or example label as a reader sees it: a phrase name without its
-- opening quote.
displayLabel :: String -> String
displayLabel ('"' : rest@('|' : _)) = rest
displayLabel label = label

-- | A local's identifier on a target. Compiler-made binders
-- (lawspecSelection0x1, lawspecFieldcents) are named by what they hold.
localIdentifier :: String -> String -> String
localIdentifier target name = nativeIdentifier target ValueName (made (dropWhile (== '_') name))
  where
    -- lawspecField<f> holds field f; lawspecSelection0x1 a selection;
    -- match_lawspecSelection0x0_0 a matched selection.
    made n = case stripPrefix "lawspecField" n of
      Just field@(_ : _) -> field
      _ | any (== "lawspec") ws, kept@(_ : _) <- filter (not . null) (map trimmed (filter (/= "lawspec") ws)) -> intercalate "_" kept
        | otherwise -> n
      where
        ws = nameWords n
        trimmed w = if any isDigit w then dropWhileEnd (`elem` ("0123456789x" :: String)) w else w

-- | A definition's name as a reader sees it. A specialised copy
-- (lawspec_count_9e2e60259d76bad2, from SpecializeDefinitions) is named
-- from its definition and its argument types (count_list_int32); its Core
-- identity keeps the digest.
readableDefinitionName :: String -> [C.Type] -> String
readableDefinitionName name arguments = case stripPrefix "lawspec_" name of
  Just rest | (digits@(_ : _), '_' : base) <- span isHexDigit (reverse rest), length digits >= 8 ->
    intercalate "_" (filter (not . null) (map (map toLower) (nameWords (reverse base)) ++ concatMap typeWords arguments))
  _ -> name

-- | A called definition's name as the spec writes it, for text about a law:
-- a specialised copy (lawspec_lawspecCollectionsSetOf_9446af497e0eb47e) is
-- named by the definition it copies, and a collections operation the
-- implicit import copies (lawspecCollectionsSetOf) by its own name (setOf).
sourceDefinitionName :: String -> String
sourceDefinitionName name = unaliased (unspecialised name)
  where
    unspecialised n = case stripPrefix "lawspec_" n of
      Just rest | (digits@(_ : _), '_' : base) <- span isHexDigit (dropWhile (== '_') (reverse rest)), length digits >= 8 ->
        reverse base
      _ -> n
    unaliased n = case stripPrefix "lawspecCollections" n of
      Just (c : cs) | isUpper c -> toLower c : cs
      _ -> n

-- | A type's words: List Int32 is list int32, a unit's Money is money.
typeWords :: C.Type -> [String]
typeWords ty = case ty of
  -- An anonymous record's identity is its shape's digest: a record, told
  -- apart by the digest's first eight digits (DEC-record-display-names).
  C.Constructor n args | "lawspec::structural::" `isPrefixOf` n ->
    ["record", take 8 (reverse (takeWhile (/= ':') (reverse n)))] ++ concat [typeWords t | C.TypeArgument t <- args]
  C.Constructor n args -> nameWords (lastSegment n) ++ concat [typeWords t | C.TypeArgument t <- args]
  C.TypeVariable _ -> ["value"]
  C.Arrow a b -> typeWords a ++ ["to"] ++ typeWords b
  where
    lastSegment s = case breakOn s of
      (_, Just rest) -> lastSegment rest
      (whole, Nothing) -> whole
    breakOn s = go [] s
      where
        go acc (':' : ':' : rest) = (reverse acc, Just rest)
        go acc (c : rest) = go (c : acc) rest
        go acc [] = (reverse acc, Nothing)
