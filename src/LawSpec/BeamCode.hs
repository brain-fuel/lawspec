-- | Erlang tokens and names shared by the BEAM emitters. Source text is never
-- reparsed for formatting, and user text never becomes an unescaped token.
-- ref:DEC-readable-output-default ref:DEC-idiomatic-generated-types
module LawSpec.BeamCode
  ( atom, binary, string, array, tuple, record, call, remote, lambda, apply
  , function, moduleDoc, moduleDocFrom, userModuleDoc, sequenceDoc, snake, moduleName, functionName
  , typeReference, reference, literal, json, value, nativeType, dataNames
  , nativeModule, nativeFunction, nativeName, pascal, elixirDataModule, elixirFields, gleamPath, gleamName
  , nativeCall, mentions, variable, comment, linkComment
  , field, assign, breaksInside, forceBreak, operator, caseOf, define, funClauses, spec, funType, comprehension, cons
  ) where

import qualified LawSpec.Code.Doc as D
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Schema as S
import qualified LawSpec.Core.Value as V
import LawSpec.Core.Types (freeExistentials)
import LawSpec.Scalar (Scalar(..), primitive, family, Family(..), integerBounds)
import Data.Char (isAscii, isAlphaNum, isUpper, isLower, isDigit, toLower, toUpper, ord)
import Data.List (intercalate, nub)
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Text as T
import Data.Foldable (toList)
import qualified Data.ByteString.Lazy.Char8 as B
import Numeric (showHex)
import Control.Monad (unless)
import LawSpec.Code.Literal (literalFor)
import LawSpec.RecordNames (recordDisplayNames)
import LawSpec.Naming (readableDefinitionName)
import qualified Data.Map.Strict as M
import LawSpec.SourceLink (labelled, generatedHeader)

-- | Quoting atoms also admits Erlang keywords as declaration names. No runtime
-- atom is created from a specification or a received value.
atom :: String -> D.Doc
atom name = D.text (if plain name then name else quote '\'' name)
  where
    plain (c:cs) = c `elem` ['a'..'z'] && all (\x -> isAscii x && (isAlphaNum x || x `elem` ("_@" :: String))) cs && name `notElem`
      words "after begin case try cond catch andalso orelse end fun if let of receive when bnot not div rem band and bor bxor bsl bsr or xor maybe else"
    plain [] = False

-- | An Erlang string: printable characters as they are, the standard
-- escapes, and \\x{...} for the rest (LawSpec.Code.Literal).
-- ref:DEC-native-string-literals
string :: String -> D.Doc
string = D.text . literalFor "erlang"

-- | A UTF-8 binary. ASCII text needs no /utf8 segment type.
binary :: String -> D.Doc
binary "" = D.text "<<>>"
binary s
  | all ((< 128) . ord) s = D.text "<<" <> string s <> D.text ">>"
  | otherwise = D.text "<<" <> string s <> D.text "/utf8>>"

quote :: Char -> String -> String
quote delimiter s = delimiter : concatMap escape s ++ [delimiter]
  where
    escape c | c == delimiter || c == '\\' = ['\\', c]
    escape '\n' = "\\n"
    escape '\r' = "\\r"
    escape '\t' = "\\t"
    escape c | ord c < 32 || ord c >= 127 = "\\x{" ++ showHex (ord c) "}"
    escape c = [c]

array, tuple :: [D.Doc] -> D.Doc
array = D.delimit 4 "[" "]"
tuple = D.delimit 4 "{" "}"

record :: [(D.Doc,D.Doc)] -> D.Doc
record fields = D.delimit 4 "#{" "}" [field "=>" a b | (a,b) <- fields]

-- | Left op right for =, => and :=, as erlfmt lays them out: a call or a
-- container on the right breaks inside its own brackets; anything else
-- moves to the next line, indented.
field :: String -> D.Doc -> D.Doc -> D.Doc
field op left right
  | breaksInside right = D.group left <> D.text (" " ++ op ++ " ") <> D.group right
  | otherwise = D.group left <> D.group (D.text (" " ++ op) <> D.nest 4 (D.softline <> D.group right))

-- | A match: Variable = Value.
assign :: String -> D.Doc -> D.Doc
assign name = field "=" (D.text name)

-- | Whether erlfmt breaks a value inside its own brackets rather than
-- before it: calls, lists, maps, funs, tuples and binaries of segments.
breaksInside :: D.Doc -> Bool
breaksInside doc = case dropWhile (== ' ') (D.render D.Compact doc) of
  '[' : _ -> True
  '#' : '{' : _ -> True
  '{' : _ -> True
  '<' : '<' : '"' : _ -> False
  '<' : '<' : '>' : '>' : _ -> False
  '<' : '<' : _ -> True
  'f' : 'u' : 'n' : c : _ | c `elem` ("( " :: String) -> True
  'b' : 'e' : 'g' : 'i' : 'n' : _ -> True
  '?' : rest -> called rest
  rest -> called rest
  where
    called s = case span nameChar s of
      (name@(c : _), ':' : more) | isLower c || c == '\'' -> case span nameChar more of
        (_ : _, '(' : _) -> not (null name)
        _ -> False
      (_ : _, '(' : _) -> True
      _ -> False
    nameChar c = isAlphaNum c || c `elem` ("_@'." :: String)

-- | Forces the groups around it to break, as erlfmt's force_breaks.
forceBreak :: D.Doc
forceBreak = D.multiline mempty

-- | An operation, parenthesised: erlfmt breaks after the operator and
-- indents the right operand.
operator :: String -> D.Doc -> D.Doc -> D.Doc
operator op left right = D.text "(" <> D.group left <>
  D.group (D.text (" " ++ op) <> D.nest 4 (D.softline <> D.group right)) <> D.text ")"

call :: String -> [D.Doc] -> D.Doc
call name args = atom name <> D.delimit 4 "(" ")" args

remote :: String -> String -> [D.Doc] -> D.Doc
remote owner name args = atom owner <> D.text ":" <> call name args

nativeCall :: String -> [String] -> [D.Doc] -> Either String D.Doc
nativeCall target parts values = do
  unless (length parts >= 2 && (target /= "erlang" || length parts == 2))
    (Left "BEAM native function references require a module and a function")
  let owner = case target of
        "erlang" -> intercalate "." (init parts)
        "elixir" -> "Elixir." ++ intercalate "." (init parts)
        _ -> intercalate "@" (init parts)
  unless (owner `notElem` ["lawspec_native_bindings","lawspec_native_generators","lawspec@native_constructors","lawspec@native_handlers","lawspec_abilities"])
    (Left "native function shadows generated BEAM binding support")
  pure (remote owner (last parts) values)

-- | A fun. A parameter its body never reads is written with a leading
-- underscore, as Erlang expects.
lambda :: [D.Doc] -> D.Doc -> D.Doc
lambda args body = D.group (D.text "fun" <> D.delimit 4 "(" ")" (map (unusedIn [body]) args) <>
  D.text " ->" <> D.nest 4 (D.softline <> body) <> D.softline <> D.text "end")

-- | A call of a computed function. A fun given one value is written
-- bind(Value, fun(X) -> ... end), so the value reads before its use; a fun
-- given several has them one to a line, as erlfmt keeps a call whose
-- callee spans lines.
apply :: D.Doc -> [D.Doc] -> D.Doc
apply f args
  | isFun, [arg] <- args = remote "lawspec_beam_runtime" "bind" [arg,f]
  | isFun, not (null args) = D.text "(" <> f <> D.text ")(" <>
      D.nest 4 (forceBreak <> D.hardline <> D.joinWith (D.text "," <> D.hardline) args) <> D.hardline <> D.text ")"
  | isFun = D.text "(" <> f <> D.text ")()"
  | length flat <= 60 = D.text ("(" ++ flat ++ ")") <> D.delimit 4 "(" ")" args
  | null args = D.text "(" <> f <> D.text ")()"
  | otherwise = D.text "(" <> f <> D.text ")(" <>
      D.nest 4 (forceBreak <> D.hardline <> D.joinWith (D.text "," <> D.hardline) args) <> D.hardline <> D.text ")"
  where
    flat = D.render D.Compact f
    isFun = take 3 flat == "fun"

-- | A fun of several clauses, each (Patterns) -> Body on lines of its own.
funClauses :: [([D.Doc], D.Doc)] -> D.Doc
funClauses clauses = forceBreak <> D.text "fun" <>
  D.nest 4 (D.hardline <> D.joinWith (D.text ";" <> D.hardline)
    [D.delimit 4 "(" ")" (map (unusedIn [body]) patterns) <> D.text " ->" <> D.nest 4 (D.hardline <> body) | (patterns, body) <- clauses]) <>
  D.hardline <> D.text "end"

-- | Expressions in sequence. Several are always one to a line.
sequenceDoc :: [D.Doc] -> D.Doc
sequenceDoc [single] = single
sequenceDoc body = forceBreak <> D.joinWith (D.text "," <> D.softline) body

-- | A function of one clause; unread parameters as lambda's.
function :: String -> [D.Doc] -> [D.Doc] -> D.Doc
function name args body = D.group (call name (map (unusedIn body) args) <> D.text " ->" <>
  D.nest 4 (D.softline <> sequenceDoc body) <> D.text ".")

moduleDoc :: String -> [(String,Int)] -> [D.Doc] -> D.Doc
moduleDoc = moduleDocFrom Nothing

-- | A generated module, its header naming the specification it comes from.
moduleDocFrom :: Maybe FilePath -> String -> [(String,Int)] -> [D.Doc] -> D.Doc
moduleDocFrom source = moduleHeader ("%% " ++ generatedHeader source)

userModuleDoc :: String -> [(String,Int)] -> [D.Doc] -> D.Doc
userModuleDoc = moduleHeader "%% User-owned LawSpec adapter. Implement these functions."

moduleHeader :: String -> String -> [(String,Int)] -> [D.Doc] -> D.Doc
moduleHeader header name exports body = D.text header <> D.hardline <>
  D.text "-module(" <> atom name <> D.text ")." <> D.hardline <>
  D.text "-export(" <> array [atom n <> D.text ("/" ++ show arity) | (n,arity) <- exports] <>
  D.text ")." <> D.hardline <> D.hardline <>
  D.joinWith (D.hardline <> D.hardline) body <> D.hardline

-- | Both camelCase and acronym names get ordinary snake_case spellings.
-- Collisions are diagnosed by the caller after this final normalization.
snake :: String -> String
snake s = intercalate "_" . filter (not . null) . split $ go Nothing s
  where
    go _ [] = []
    go previous (c:rest)
      | not (isAscii c && isAlphaNum c) = '_' : go Nothing rest
      | otherwise = (if boundary previous c rest then "_" else "") ++ [toLower c] ++ go (Just c) rest
    boundary (Just p) c rest = isUpper c && (isLower p || isDigit p ||
      isUpper p && case rest of n:_ -> isLower n; _ -> False)
    boundary _ _ _ = False
    split text = case break (== '_') text of (a,[]) -> [a]; (a,_:b) -> a : split b

moduleName :: C.Id -> String
moduleName = snake . C.idText

-- | A declaration's native function: its name, or a specialised copy's
-- definition and argument types (count_list_int32).
functionName :: C.Declaration -> String
functionName declaration = case snake (readableDefinitionName (C.declarationName declaration) (fst (C.functionType (C.declarationType declaration)))) of
  "module_info" -> "lawspec_module_info"
  name -> name

-- | Elixir modules retain namespaces; their VM names carry the Elixir prefix.
nativeModule :: String -> C.Unit -> String
nativeModule "elixir" = ("Elixir." ++) . intercalate "." . map pascal . splitDot . C.idText . C.unitId
  where splitDot s = case break (== '.') s of (a,[]) -> [a]; (a,_:b) -> a : splitDot b
nativeModule "gleam" = map (\c -> if c == '/' then '@' else c) . gleamPath . C.unitId
nativeModule _ = moduleName . C.unitId

nativeFunction :: String -> C.Declaration -> String
nativeFunction target = nativeName target . functionName

nativeName :: String -> String -> String
nativeName "elixir" name = case name of
  n | n `elem` words "after alias and case catch cond def defmodule do else end false fn for if import in nil not or quote raise receive require rescue super true try unless unquote use when with __info__" -> n ++ "_lawspec"
  n -> n
nativeName "gleam" name = gleamName name
nativeName _ name = name

gleamPath :: C.Id -> String
gleamPath = intercalate "/" . map (gleamName . snake) . splitDot . C.idText
  where splitDot s = case break (== '.') s of (a,[]) -> [a]; (a,_:b) -> a : splitDot b

gleamName :: String -> String
gleamName n | n `elem` words "as assert auto case const delegate derive echo else fn if implement import let opaque panic pub test todo type use" = n ++ "_lawspec"
gleamName n = n

pascal :: String -> String
pascal = concatMap cap . words . map (\c -> if c == '_' then ' ' else c) . snake
  where cap [] = []; cap (c:cs) = toUpper c : cs

elixirDataModule :: String -> String
elixirDataModule = ("LawSpec.Data." ++) . pascal

elixirFields :: C.DataDeclaration -> C.DataConstructor -> [String]
elixirFields d c = map (snake . C.binderName) (C.constructorFields c) ++
  ["lawspec_type_" ++ show i | (i,_) <- zip [0::Int ..] (freeExistentials d c)]

-- | Type parameters stay positional in runtime metadata.
reference :: S.TypeRef -> D.Doc
reference (S.Parameter i) = tuple [atom "parameter", D.text (show i)]
reference (S.Named n args) = tuple [binary n, array (map reference args)]

typeReference :: C.Type -> Either String D.Doc
typeReference ty = reference <$> S.typeReference [] ty

-- | Lossless wire leaves are emitted as Erlang literals. JSON object keys are
-- binaries, including keys unknown to the runtime; none intern new atoms.
json :: A.Value -> D.Doc
json j = case j of
  A.Object fields -> record [(binary (K.toString k),json v) | (k,v) <- KM.toAscList fields]
  A.Array xs -> array (map json (toList xs))
  A.String s -> binary (T.unpack s)
  A.Number n -> D.text (B.unpack (A.encode n))
  A.Bool b -> atom (if b then "true" else "false")
  A.Null -> atom "null"

-- | A scalar as the runtime holds it, written natively: integers, booleans,
-- Text as a UTF-8 binary, Bytes as a binary, exact and IEEE numbers through
-- their runtime constructors. Others go through the runtime's literal.
literal :: D.Doc -> Scalar -> D.Doc
literal symbols s = case s of
  SInteger _ n -> D.text (show n)
  SCharacter _ n -> D.text (show n)
  SBool b -> atom (if b then "true" else "false")
  SSequence "Text" units -> binary (map toEnum units)
  SSequence "Bytes" units -> D.text ("<<" ++ intercalate ", " (map show units) ++ ">>")
  SDecimal c e -> remote "lawspec_beam_scalar" "decimal" [D.text (show c),D.text (show e)]
  SRational n d -> remote "lawspec_beam_scalar" "ratio" [D.text (show n),D.text (show d)]
  SFloat t bits | t `elem` ["Float32","Float64"] ->
    remote "lawspec_beam_scalar" "float_bits" [D.text (drop 5 t),D.text ("16#" ++ bits)]
  SAbsent "Unit" -> atom "ls_unit"
  SAbsent "Null" -> atom "ls_null"
  SAbsent "Undefined" -> atom "ls_undefined"
  _ -> remote "lawspec_beam_scalar" "literal" [json (A.toJSON s),symbols]

value :: D.Doc -> V.Value -> D.Doc
value symbols v = case v of
  V.ScalarValue s -> literal symbols s
  V.DataValue _ (C.Id "List::Nil") [] -> array []
  V.DataValue _ (C.Id "List::Cons") [_,_] | Right items <- V.listItems v -> array (map (value symbols) items)
  V.DataValue _ (C.Id "List::Cons") [h,t] ->
    cons (value symbols h) (value symbols t)
  V.DataValue _ tag fields -> tuple [atom "ls_data",binary (C.idText tag),array (map (value symbols) fields)]
  V.PresenceValue (C.Constructor n _) item -> tuple [atom "ls_presence",binary n,
    maybe (atom "none") (\x -> tuple [atom "some",value symbols x]) item]
  V.PresenceValue _ _ -> error "non-constructor presence in checked Core"

-- | A program has one data module. Ambiguous short names are qualified by
-- their resolved unit, and a remaining collision is reported before emission.
dataNames :: [C.DataDeclaration] -> Either String [(C.Id,String)]
dataNames declarations = do
  -- An anonymous record is named from where it is used (LawSpec.RecordNames).
  let display = recordDisplayNames declarations
      shorts = [(C.dataId d,snake (M.findWithDefault (C.dataName d) (C.dataId d) display)) | d <- declarations]
      reservedTypes = words "any none no_return atom map pid port reference tuple integer int float number binary bitstring bit_array boolean bool char string nonempty_string list nonempty_list improper_list nonempty_improper_list maybe_improper_list nonempty_maybe_improper_list byte arity identifier iodata iolist mfa module node timeout fun function term nothing just left right some non_null null undefined ok nil true false result utf_codepoint charlist nonempty_charlist as_boolean"
      -- Built-in types Erlang and Elixir let a module redefine, with a
      -- warning: only the type's name moves, its constructors keep their tags.
      builtinTypes = words "record dynamic neg_integer non_neg_integer pos_integer nonempty_binary nonempty_bitstring"
      tagNames = [(identity, if length (filter ((== n) . snd) shorts) > 1 || n `elem` reservedTypes
        then snake (C.idText identity) else n) | (identity,n) <- shorts]
      types = [(identity, if n `elem` builtinTypes then qualified identity n else n) | (identity,n) <- tagNames]
      qualified identity n = if snake (C.idText identity) == n then n ++ "_type" else snake (C.idText identity)
      constructors = [(C.constructorId c, if length (C.dataConstructors d) == 1 then n
        else n ++ "_" ++ snake (C.constructorName c))
        | d <- declarations, Just n <- [lookup (C.dataId d) tagNames], c <- C.dataConstructors d]
      duplicates xs = [n | n <- nub (map snd xs), length (filter ((== n) . snd) xs) > 1]
      names = map snd types
      tags = map snd constructors
  if any (\n -> null n || length n > 255) (names ++ tags)
    then Left "BEAM data name is empty or exceeds the Erlang atom limit"
    else if length names /= length (nub names) || length tags /= length (nub tags)
    then Left ("colliding BEAM data names: " ++ show (duplicates (types ++ constructors)))
    else pure (types ++ constructors)

-- | Native Erlang interfaces use tuples, binaries, lists and bounded integers.
-- IEEE values are opaque bit-preserving wrappers, including infinity and NaN.
nativeType :: Int -> [(C.Id,String)] -> [(C.Id,String)] -> C.Type -> Either String D.Doc
nativeType bits names parameters ty = case ty of
  C.TypeVariable identity -> maybe (Left "unbound BEAM native type parameter") (Right . D.text) (lookup identity parameters)
  C.Constructor n args -> do
    ts <- mapM argument args
    case (n,ts) of
      ("List",[t]) -> pure (array [t])
      ("Maybe",[t]) -> pure (union [atom "absent",tuple [atom "present",t]])
      ("Either",[a,b]) -> pure (union [tuple [atom "left",a],tuple [atom "right",b]])
      ("Nullable",[t]) -> pure (union [atom "null",tuple [atom "non_null",t]])
      ("Optional",[t]) -> pure (union [atom "none",tuple [atom "some",t]])
      (_,[]) | Just p <- primitive n -> pure $ case family p of
        IntegerFamily -> case integerBounds bits n of
          Just (lo,hi) -> D.text (show lo ++ ".." ++ show hi)
          Nothing -> call (if n == "BigUInt" then "non_neg_integer" else "integer") []
        Boolean -> call "boolean" []
        Floating -> remote "lawspec_beam_scalar" "ieee" []
        Complex -> remote "lawspec_beam_scalar" "complex" []
        Exact -> remote "lawspec_beam_scalar" (map toLower n) []
        Character -> call "non_neg_integer" []
        Sequence -> if n `elem` ["Text","Bytes"] then call "binary" [] else array [call "non_neg_integer" []]
        Identity -> remote "lawspec_beam_scalar" "symbol" []
        Absence -> atom (case n of "Unit" -> "ok"; "Null" -> "null"; _ -> "undefined")
      _ -> maybe (Left ("no BEAM native type: " ++ n))
        (\name -> pure (remote "lawspec_data" name ts)) (lookup (C.Id n) names)
  C.Arrow _ _ -> Left "function-valued BEAM data is unsupported"
  where
    argument (C.TypeArgument t) = nativeType bits names parameters t
    argument (C.IndexArgument _) = Left "unerased BEAM type index"
    -- A union breaks before each "| ", as erlfmt breaks one.
    union = D.group . D.joinWith (D.softline <> D.text "| ")

-- | Whether generated code reads a variable: its name as a token outside
-- string, character and comment text. Generated code names a variable it
-- binds only when it reads it, as Erlang warns of unused ones.
mentions :: String -> D.Doc -> Bool
mentions name doc = name `elem` tokens (D.render D.Compact doc)
  where
    tokens s = case s of
      [] -> []
      '"' : rest -> tokens (skipQuoted '"' rest)
      '\'' : rest -> tokens (skipQuoted '\'' rest)
      '$' : '\\' : _ : rest -> tokens rest
      '$' : _ : rest -> tokens rest
      '%' : rest -> tokens (dropWhile (/= '\n') rest)
      c : _ | isAlphaNum c || c == '_' -> let (t, rest) = span (\x -> isAlphaNum x || x `elem` ("_@" :: String)) s in t : tokens rest
      _ : rest -> tokens rest
    skipQuoted q s = case s of
      [] -> []
      '\\' : _ : rest -> skipQuoted q rest
      c : rest | c == q -> rest
               | otherwise -> skipQuoted q rest

-- | A parameter that is a plain variable, underscored when the code
-- after it never reads it.
unusedIn :: [D.Doc] -> D.Doc -> D.Doc
unusedIn scope parameter = case D.render D.Compact parameter of
  name@(c : rest) | isUpper c, all (\x -> isAlphaNum x || x `elem` ("_@" :: String)) rest,
                    not (any (mentions name) scope) -> D.text ('_' : name)
  _ -> parameter

-- | A bound variable, written with a leading underscore when its scope
-- never reads it.
variable :: String -> D.Doc -> D.Doc
variable name scope = D.text (if mentions name scope then name else "_" ++ name)

-- | A comment's lines, each a line of its own.
comment :: [String] -> D.Doc
comment = mconcat . map (\line -> D.text ("%%" ++ (if null line then "" else " " ++ line)) <> D.hardline)

-- | The one-line comment linking generated code to its source.
linkComment :: String -> Maybe String -> D.Doc
linkComment label link = comment [labelled label link]

-- | case Subject of Pattern -> Body; ... end, each clause's body on its
-- own line, as erlfmt keeps it.
caseOf :: D.Doc -> [(D.Doc, D.Doc)] -> D.Doc
caseOf subject clauses = forceBreak <> D.group (D.text "case" <> D.nest 4 (D.softline <> subject) <> D.softline <> D.text "of") <>
  D.nest 4 (D.hardline <> D.joinWith (D.text ";" <> D.hardline)
    [pattern <> D.text " ->" <> D.nest 4 (D.hardline <> body) | (pattern, body) <- clauses]) <>
  D.hardline <> D.text "end"

-- | -define(Name, Value).
define :: String -> D.Doc -> D.Doc
define name value = D.group (D.text ("-define(" ++ name ++ ",") <> D.nest 4 (D.softline <> value) <> D.softbreak <> D.text ")") <> D.text "."

-- | -spec Name(Args) -> Result., the result on the next line when the
-- line is too long, as erlfmt writes a one-clause spec.
spec :: String -> [D.Doc] -> D.Doc -> D.Doc
spec name args result = D.text "-spec " <> call name args <>
  D.group (D.text " ->" <> D.nest 4 (D.softline <> result)) <> D.text "."

-- | fun((Args) -> Result), as erlfmt breaks a fun type.
funType :: [D.Doc] -> D.Doc -> D.Doc
funType args result = D.group (D.text "fun(" <> D.nest 4 (D.softbreak <> D.delimit 4 "(" ")" args <>
  D.group (D.text " ->" <> D.nest 4 (D.softline <> result))) <> D.softbreak <> D.text ")")

-- | [Expression || Pattern <- Source], as erlfmt breaks a comprehension.
comprehension :: D.Doc -> D.Doc -> D.Doc -> D.Doc
comprehension expression pattern source = D.group (D.text "[" <> D.nest 4 (D.softbreak <> expression) <>
  D.softbreak <> D.text " || " <> D.nest 4 (D.group (field "<-" pattern source)) <> D.softbreak <> D.text "]")

-- | [Head | Tail].
cons :: D.Doc -> D.Doc -> D.Doc
cons h t = D.group (D.text "[" <> D.nest 4 (D.softbreak <> D.group (h <> D.softline <> D.text "| " <> t)) <> D.softbreak <> D.text "]")
