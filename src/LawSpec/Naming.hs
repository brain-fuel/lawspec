-- | One place decides the names generated code uses. Source names are kept,
-- cased the way the target writes them; a keyword is escaped the target's own
-- way; a collision gets _2, _3 in declaration order. Compiler-made values
-- have short names that say what they hold. Core identities never change:
-- these are spellings only. ref:DEC-readable-generated-names
module LawSpec.Naming
  ( Casing(..), NameKind(..), nameWords, cased, casingFor, escapeKeyword, reservedFor
  , nativeIdentifier, Scope, emptyScope, scopeWith, claim, claimAll, uniqueNames
  , testName, exampleTestSuffix, boundaryTestSuffix, displayLabel, localIdentifier, readableDefinitionName, sourceDefinitionName, typeWords
  , ParameterName(..), parameterWords, typeHeadWords, parameterIdentifier, parameterNames, parameterNamesWith
  , declarationParameterNames, operationParameterNames, handlerParameterNames, sourceParameterNames, positionalParameters, positionalNames, suffixedNames, paddedNames, helperNames, fieldCodecNames, fieldHelperNames
  ) where

import Data.Binary (Binary)
import GHC.Generics (Generic)
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
newtype Scope = Scope (S.Set String) deriving (Eq, Show, Generic)

instance Binary Scope

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
    lastSegment = lastTypeSegment

-- | The words of a type's head, which name an unnamed parameter: List Text
-- is list, Maybe Order is maybe, a unit's OrderLine is order line. An
-- unsigned integer keeps its u (UInt32 is uint32), Whole is whole, an
-- anonymous record is record, a type variable is value and a function is
-- function.
typeHeadWords :: C.Type -> [String]
typeHeadWords ty = case ty of
  C.Constructor n _ | "lawspec::structural::" `isPrefixOf` n -> ["record"]
  C.Constructor "BigUInt" _ -> ["whole"]
  C.Constructor n _ -> case nameWords (unsigned (lastTypeSegment n)) of
    [] -> ["value"]
    ws -> ws
  C.TypeVariable _ -> ["value"]
  C.Arrow _ _ -> ["function"]
  where
    unsigned n = case stripPrefix "UInt" n of
      Just rest -> "Uint" ++ rest
      Nothing -> n

-- | A parameter's name before a target spells it.
-- ref:DEC-generated-parameter-names
data ParameterName
  = DeclaredName String      -- ^ the name its signature declares
  | TypeDerivedName [String] Int
    -- ^ its type's head and its number, from 1, among the unnamed
    -- parameters with that head
  | PositionalName Int       -- ^ its position, from 0: the reference spelling
  deriving (Eq, Show)

-- | Every parameter's name, in order: the declared one, or else one made
-- from its type. add :: (a :: Int32) -> Int32 -> Int32 -> Text has a,
-- int32 1 and int32 2. A sole unnamed parameter of its type is numbered
-- too, so adding a second never renames the first.
parameterWords :: C.ParameterNames -> [C.Type] -> [ParameterName]
parameterWords C.PositionalParameters types = [PositionalName i | (i, _) <- zip [0 ..] types]
parameterWords (C.DeclaredParameters declared) types = go [] (zip (declared ++ repeat Nothing) types)
  where
    go _ [] = []
    go seen ((Just name, _) : rest) | not (null (nameWords name)) = DeclaredName name : go seen rest
    go seen ((_, ty) : rest) =
      let hd = typeHeadWords ty
          number = 1 + length (filter (== hd) seen)
      in TypeDerivedName hd number : go (hd : seen) rest

-- | One parameter's name in a casing, escaped by the target's own rule. A
-- type-derived name ends in its number, joined as the casing joins a number
-- (numbered): int32_1 and order_line_1, int32_1 and orderLine1, int32-1.
parameterIdentifier :: Casing -> (String -> String) -> String -> ParameterName -> String
parameterIdentifier casing escape positional name = case name of
  DeclaredName source -> escape (leading (cased casing (nameWords source)))
  TypeDerivedName ws number -> numbered casing (cased casing ws) number
  PositionalName i -> positional ++ show i
  where
    leading identifier@(c : _) | isDigit c = (if casing == Pascal then 'V' else 'v') : identifier
    leading identifier = identifier

-- | A name and a number after it. snake_case and kebab-case separate every
-- word, so the number follows an underscore or a hyphen. camelCase has no
-- separator, so the number follows directly (text1, orderLine1), except
-- after a digit, where an underscore keeps two numbers apart (int32_1), as
-- Google's Java guide writes adjacent numbers (5.3, guava33_4_6).
numbered :: Casing -> String -> Int -> String
numbered casing name number = name ++ separator ++ show number
  where
    separator = case casing of
      Kebab -> "-"
      Camel | not endsInDigit -> ""
      Pascal | not endsInDigit -> ""
      _ -> "_"
    endsInDigit = not (null name) && isDigit (last name)

-- | A function's parameter names on a target: cased as the target cases a
-- value, clear of its reserved words, of the names already taken where they
-- are declared, and of each other (a clash is numbered from 2, in order).
-- The positional stem is what the reference spelling numbers (value gives
-- value0, value1); those names are exactly the earlier releases' and are
-- not adjusted.
parameterNames :: String -> [String] -> String -> C.ParameterNames -> [C.Type] -> [String]
parameterNames target = parameterNamesWith (casingFor target ValueName) (escapeKeyword target)

-- | The same for a target with its own casing or escape.
parameterNamesWith :: Casing -> (String -> String) -> [String] -> String -> C.ParameterNames -> [C.Type] -> [String]
parameterNamesWith casing escape taken positional declared types = case declared of
  C.PositionalParameters -> spelled
  _ -> distinct (S.fromList taken) spelled
  where
    spelled = map (parameterIdentifier casing escape positional) (parameterWords declared types)
    distinct _ [] = []
    distinct used (name : rest) =
      let chosen = case [c | c <- name : [numbered casing name n | n <- [2 :: Int ..]], c `S.notMember` used] of
            c : _ -> c
            [] -> name
      in chosen : distinct (S.insert chosen used) rest

-- | An adapter's or definition's parameter names on a target.
declarationParameterNames :: String -> [String] -> String -> C.Declaration -> [String]
declarationParameterNames target taken positional d =
  parameterNames target taken positional (C.declarationParameters d) (fst (C.functionType (C.declarationType d)))

-- | An ability operation's parameter names on a target. The built-in
-- units' abilities declare theirs (LawSpec.Builtins), and the runtime's
-- default handlers are written with the same names.
operationParameterNames :: String -> [String] -> String -> C.Ability -> String -> [String]
operationParameterNames target taken positional ability operation =
  parameterNames target taken positional (C.operationParameters ability operation)
    (maybe [] (fst . C.functionType) (lookup operation (C.abilityOperations ability)))

-- | The names of the handlers a generated function takes, one for each
-- ability it uses: the ability's name cased as the target cases a value
-- (gateway, order_store), a clash numbered from 2.
handlerParameterNames :: String -> [String] -> [C.AbilityRef] -> [String]
handlerParameterNames target taken refs =
  parameterNames target taken "handler" (C.DeclaredParameters [Just (lastTypeSegment (C.idText (C.abilityRefId ref))) | ref <- refs])
    (map (const (C.scalarType "Unit")) refs)

-- | Parameter names as text about the spec gives them (a failure, explain):
-- the declared name as written, or the type-derived one in snake_case.
sourceParameterNames :: C.ParameterNames -> [C.Type] -> [String]
sourceParameterNames declared types = fst (claimAll emptyScope [ case name of
    DeclaredName source -> source
    _ -> parameterIdentifier Snake id "value" name
  | name <- parameterWords declared types ])

-- | The reference spelling on a stem: value0, value1, ... Generated code a
-- user neither implements nor calls by name keeps it for its own locals.
positionalNames :: String -> [String]
positionalNames stem = [stem ++ show i | i <- [0 :: Int ..]]

-- | A declaration with the reference spelling of its parameters.
positionalParameters :: C.Declaration -> C.Declaration
positionalParameters d = d { C.declarationParameters = C.PositionalParameters }

lastTypeSegment :: String -> String
lastTypeSegment = lastSegment
  where
    lastSegment s = case breakOn s of
      (_, Just rest) -> lastSegment rest
      (whole, Nothing) -> whole
    breakOn s = go [] s
      where
        go acc (':' : ':' : rest) = (reverse acc, Just rest)
        go acc (c : rest) = go (c : acc) rest
        go acc [] = (reverse acc, Nothing)

-- | The names of the helper locals generated code makes one of for each
-- parameter (pathCodec, path_value): the parameter's name, without its
-- keyword escape, and a suffix. Where one of them would collide with a name
-- already in use or with another, all of them fall back to the positional
-- stem (codec0, codec1), which no parameter is ever called.
-- ref:DEC-generated-parameter-names
suffixedNames :: [String] -> String -> String -> [String] -> [String]
suffixedNames taken suffix = derivedNames taken (++ suffix)

-- | suffixedNames with any way of making a helper's name from a parameter's.
derivedNames :: [String] -> (String -> String) -> String -> [String] -> [String]
derivedNames taken make positional names
  | distinct && all (`notElem` (taken ++ names)) made = made
  | otherwise = take (length names) (positionalNames positional)
  where
    made = map (make . plain) names
    distinct = S.size (S.fromList made) == length made
    plain name = case filter (/= '`') (maybe name id (stripPrefix "r#" name)) of
      stripped -> case dropWhileEnd (== '_') stripped of
        "" -> stripped
        bare -> bare

-- | Exactly n names: those given, then positional ones on the stem for any
-- the declaration did not supply.
paddedNames :: Int -> String -> [String] -> [String]
paddedNames n positional names = take n (names ++ drop (length names) (positionalNames positional))

-- | The helper locals named after parameters with a word, cased as the
-- target cases a value: path and "codec" give pathCodec in Java, path_codec
-- in Python. In camelCase a name whose first word is one letter takes the
-- word in front (codecN, never nCodec): Google's Java guide, 5.3, and the
-- checkers that follow it allow no one-letter first word before a capital.
helperNames :: Casing -> [String] -> String -> [String] -> [String]
helperNames casing taken word = derivedNames taken make word
  where
    capital text = case text of
      c : rest -> toUpper c : rest
      [] -> []
    make name = case casing of
      Snake -> name ++ "_" ++ word
      ScreamingSnake -> name ++ "_" ++ map toUpper word
      Kebab -> name ++ "-" ++ word
      _ | oneLetterStart name -> word ++ capital name
        | otherwise -> name ++ capital word
    oneLetterStart name = case name of
      [_] -> True
      _ : second : _ -> not (isLower second || isDigit second)
      [] -> True

-- | The locals that hold one codec for each field of a constructor: the
-- field's name and the word codec (amountCodec), or field0, field1 where a
-- field has no usable name.
fieldCodecNames :: String -> [String] -> [String] -> [String]
fieldCodecNames = fieldHelperNames "codec"

-- | The locals generated code makes one of for each field of a constructor:
-- the field's name and a word (amountCodec, amount_field), or field0,
-- field1 where a field has no usable name.
fieldHelperNames :: String -> String -> [String] -> [String] -> [String]
fieldHelperNames word target taken fields
  | any null identifiers = take (length fields) (positionalNames "field")
  | otherwise = helperNames (casingFor target ValueName) taken word identifiers
  where identifiers = [if null (nameWords field) then "" else localIdentifier target field | field <- fields]
