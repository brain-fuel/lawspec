-- | Elixir tokens and native types; the checked expression implementation is
-- shared Erlang, while public functions and data stay idiomatic Elixir.
-- ref:DEC-idiomatic-generated-types ref:DEC-readable-output-default
module LawSpec.ElixirCode
  ( string, atom, array, tuple, call, remote, function, moduleDoc, moduleDocFrom, integer, layoutFor, typeAttribute, variables
  , nativeType, nativeTypeLayout, TypeLayout(..), typeDoc, typeReference, reference ) where

import qualified LawSpec.Core as C
import qualified LawSpec.Core.Schema as S
import qualified LawSpec.Code.Doc as D
import LawSpec.Scalar (primitive, family, Family(..), integerBounds)
import Data.Char (ord, toLower, isAscii, isAlphaNum, isLower)
import Numeric (showHex)
import LawSpec.SourceLink (generatedHeader)
import LawSpec.Naming (claimAll, scopeWith, nativeIdentifier, NameKind(..))

string :: String -> D.Doc
string s = D.text ('"' : concatMap escape s ++ "\"")
  where
    escape c | c `elem` ['"','\\','#'] = ['\\',c]
    escape '\n' = "\\n"
    escape '\r' = "\\r"
    escape '\t' = "\\t"
    escape c | ord c < 32 || ord c >= 127 = "\\u{" ++ showHex (ord c) "}"
    escape c = [c]

atom :: String -> D.Doc
atom n = D.text ":" <> (if plain n then D.text n else string n)
  where
    plain (c:cs) = (isAscii c && isLower c || c == '_') && all (\x -> isAscii x && (isAlphaNum x || x `elem` ("_@!?" :: String))) cs
    plain [] = False

array, tuple :: [D.Doc] -> D.Doc
array = D.delimit 2 "[" "]"
tuple = D.delimit 2 "{" "}"

call :: String -> [D.Doc] -> D.Doc
call name args = D.text name <> D.delimit 2 "(" ")" args

remote :: String -> String -> [D.Doc] -> D.Doc
remote owner name args = D.text owner <> D.text "." <> call name args

-- | def name(args) do ... end, its body on lines of its own, as mix
-- format writes a do block.
function :: String -> [D.Doc] -> [D.Doc] -> D.Doc
function name args body = D.text "def " <>
  D.prefixChoice headText (D.group (D.text headText)) (D.nest 4 (call name args)) <> D.text " do" <>
  D.nest 2 (D.hardline <> D.joinWith D.hardline body) <> D.hardline <> D.text "end"
  where headText = D.render D.Compact (call name args)

-- | Logical Elixir type syntax. Atomic references are indivisible; calls,
-- unions, containers, map fields and arrows retain their checked structure.
data TypeLayout
  = TypeAtom D.Doc
  | TypeCall String [TypeLayout]
  | TypeUnion [TypeLayout]
  | TypeContainer String [TypeLayout] String
  | TypeMapField D.Doc TypeLayout
  | TypeKeywordField String TypeLayout
  | TypeFunction [TypeLayout] TypeLayout

-- | The ordinary type document, independent of its attribute's alignment.
typeDoc :: TypeLayout -> D.Doc
typeDoc ty = case ty of
  TypeAtom doc -> doc
  TypeCall name args -> call name (map typeDoc args)
  TypeUnion alternatives -> D.joinWith (D.text " | ") (map typeDoc alternatives)
  TypeContainer open items close -> D.delimit 2 open close (map typeDoc items)
  TypeMapField key value -> key <> D.text " => " <> typeDoc value
  TypeKeywordField key value -> D.text (key ++ ": ") <> typeDoc value
  TypeFunction args result -> D.text "(" <> mconcat
    [D.joinWith (D.text ", ") (map typeDoc args) <> D.text " " | not (null args)] <>
    D.text "-> " <> typeDoc result <> D.text ")"

-- | @spec or @type uses the type constructors to select Mix's attribute
-- alignment. Rendering measures widths only; no printed syntax is parsed.
typeAttribute :: String -> TypeLayout -> TypeLayout -> D.Doc
typeAttribute attribute left (TypeUnion [right]) = typeAttribute attribute left right
typeAttribute attribute left right
  | 2 + length flat <= 98 = D.text flat
  | TypeUnion alternatives <- right, length alternatives > 1,
    2 + length (prefix ++ l ++ " ::") <= 98 = D.text (prefix ++ l ++ " ::") <> D.hardline <> rightAlone
  | TypeContainer open items close <- right, 2 + length (prefix ++ l ++ " :: " ++ open) <= 98 =
      D.text (prefix ++ l ++ " :: " ++ open) <>
      mconcat [D.hardline <> item i (if k < length items then "," else "") | (k, i) <- zip [1 :: Int ..] items] <>
      D.hardline <> D.text (replicate 6 ' ' ++ close)
  | 2 + length (prefix ++ l) <= 98 = D.text (prefix ++ l ++ " ::") <> D.hardline <> rightAlone
  | TypeCall name [TypeContainer "[" items "]"] <- left =
      D.text (prefix ++ name ++ "([") <>
      mconcat [D.hardline <> D.text (replicate 8 ' ' ++ flatType i ++ (if k < length items then "," else "")) | (k, i) <- zip [1 :: Int ..] items] <>
      D.hardline <> closing "])"
  | TypeCall name args <- left =
      D.text (prefix ++ name ++ "(") <>
      mconcat [D.hardline <> argument a (if k < length args then "," else "") | (k, a) <- zip [1 :: Int ..] args] <>
      D.hardline <> closing ")"
  | otherwise = D.text flat
  where
    flatType = D.render D.Compact . typeDoc
    closing bracket
      | 8 + length (bracket ++ " :: " ++ r) <= 98 = D.text (replicate 6 ' ' ++ bracket ++ " :: " ++ r)
      | otherwise = D.text (replicate 6 ' ' ++ bracket ++ " ::") <> D.hardline <> rightAlone
    argument a suffix = case a of
      TypeUnion alternatives@(_ : _ : _) -> D.joinWith D.hardline
        [D.text (replicate 8 ' ' ++ (if i == 0 then "" else "| ") ++ flatType x ++ (if i + 1 == length alternatives then suffix else ""))
        | (i, x) <- zip [0 :: Int ..] alternatives]
      _ -> D.text (replicate 8 ' ' ++ flatType a ++ suffix)
    rightAlone
      | 10 + length r <= 98 = D.text (replicate 8 ' ' ++ r)
      | TypeUnion alternatives@(_ : _ : _) <- right = D.joinWith D.hardline
          [D.text (replicate 8 ' ' ++ (if i == 0 then "" else "| ") ++ flatType a) | (i, a) <- zip [0 :: Int ..] alternatives]
      | TypeCall name args <- right = D.text (replicate 8 ' ' ++ name ++ "(") <>
          mconcat [D.hardline <> D.text (replicate 10 ' ' ++ flatType a ++ (if k < length args then "," else "")) | (k, a) <- zip [1 :: Int ..] args] <>
          D.hardline <> D.text (replicate 8 ' ' ++ ")")
      | otherwise = D.text (replicate 8 ' ' ++ r)
    prefix = "@" ++ attribute ++ " "
    l = flatType left
    r = flatType right
    flat = prefix ++ l ++ " :: " ++ r
    item i suffix
      | 10 + length (flatType i) + length suffix <= 98 = D.text (replicate 8 ' ' ++ flatType i ++ suffix)
      | TypeMapField key (TypeFunction args (TypeUnion alternatives@(_ : _ : _))) <- i =
          let arguments = D.render D.Compact (D.joinWith (D.text ", ") (map typeDoc args))
              keyText = D.render D.Compact key
              opening = replicate 8 ' ' ++ keyText ++ " => (" ++ arguments ++ (if null args then "-> " else " -> ")
              resultColumn = 8 + length keyText + 4 + 1 + 2
              alternatives' = [(if k == 0 then "" else "| ") ++ flatType alt ++ (if k + 1 == length alternatives then ")" ++ suffix else "") | (k, alt) <- zip [0 :: Int ..] alternatives]
          in if null args
            then D.text (opening ++ concat (take 1 alternatives')) <> mconcat [D.hardline <> D.text (replicate (length opening) ' ' ++ alt) | alt <- drop 1 alternatives']
            else D.text (replicate 8 ' ' ++ keyText ++ " => (" ++ arguments ++ " ->") <>
              mconcat [D.hardline <> D.text (replicate resultColumn ' ' ++ alt) | alt <- alternatives']
      | TypeMapField key (TypeFunction args result) <- i =
          let arguments = D.render D.Compact (D.joinWith (D.text ", ") (map typeDoc args))
              keyText = D.render D.Compact key
          in D.text (replicate 8 ' ' ++ keyText ++ " => (" ++ arguments ++ " ->") <> D.hardline <>
            D.text (replicate (8 + length keyText + 4 + 1 + 2) ' ' ++ flatType result ++ ")" ++ suffix)
      | TypeMapField key value <- i = D.text (replicate 8 ' ' ++ D.render D.Compact key ++ " =>") <>
          D.hardline <> D.text (replicate 10 ' ' ++ flatType value ++ suffix)
      | otherwise = D.text (replicate 8 ' ' ++ flatType i ++ suffix)

moduleDoc :: String -> Bool -> [D.Doc] -> D.Doc
moduleDoc name editable = moduleWith (if editable then "# User-owned LawSpec adapter. Implement these functions." else "# " ++ generatedHeader Nothing) name

-- | A generated module whose header names its specification.
moduleDocFrom :: Maybe FilePath -> String -> [D.Doc] -> D.Doc
moduleDocFrom source = moduleWith ("# " ++ generatedHeader source)

moduleWith :: String -> String -> [D.Doc] -> D.Doc
moduleWith header name body = D.text header <>
  D.hardline <> D.text ("defmodule " ++ name ++ " do") <>
  (if null body then mempty else D.nest 2 (D.hardline <> D.joinWith (D.hardline <> D.hardline) body)) <> D.hardline <> D.text "end" <> D.hardline

-- | mix format's line width, 98, for the BEAM layout.
layoutFor :: D.Layout -> D.Layout
layoutFor layout = case layout of
  D.Pretty _ -> D.Pretty 98
  other -> other

-- | An integer as mix format writes it: digits grouped by underscores from
-- six digits on.
integer :: Integer -> D.Doc
integer n = D.text ((if n < 0 then "-" else "") ++ grouped (show (abs n)))
  where
    grouped digits
      | length digits < 6 = digits
      | otherwise = reverse (go (reverse digits))
    go (a : b : c : rest@(_ : _)) = a : b : c : '_' : go rest
    go rest = rest

reference :: S.TypeRef -> D.Doc
reference (S.Parameter i) = tuple [atom "parameter",D.text (show i)]
reference (S.Named n ts) = tuple [string n,array (map reference ts)]

typeReference :: C.Type -> Either String D.Doc
typeReference ty = reference <$> S.typeReference [] ty

nativeType :: Int -> [(C.Id,String)] -> [(C.Id,String)] -> C.Type -> Either String D.Doc
nativeType bits names parameters ty = typeDoc <$> nativeTypeLayout bits names parameters ty

nativeTypeLayout :: Int -> [(C.Id,String)] -> [(C.Id,String)] -> C.Type -> Either String TypeLayout
nativeTypeLayout bits names parameters ty = case ty of
  C.TypeVariable identity -> maybe (Left "unbound Elixir type parameter") (Right . TypeAtom . D.text) (lookup identity parameters)
  C.Constructor n args -> do
    ts <- mapM argument args
    case (n,ts) of
      ("List",[t]) -> pure (TypeContainer "[" [t] "]")
      ("Maybe",[t]) -> pure (union [TypeAtom (atom "absent"),TypeContainer "{" [TypeAtom (atom "present"),t] "}"])
      ("Either",[a,b]) -> pure (union [TypeContainer "{" [TypeAtom (atom "left"),a] "}",TypeContainer "{" [TypeAtom (atom "right"),b] "}"])
      ("Nullable",[t]) -> pure (union [TypeAtom (atom "null"),TypeContainer "{" [TypeAtom (atom "non_null"),t] "}"])
      ("Optional",[t]) -> pure (union [TypeAtom (atom "none"),TypeContainer "{" [TypeAtom (atom "some"),t] "}"])
      (_,[]) | Just p <- primitive n -> pure $ case family p of
        IntegerFamily -> case integerBounds bits n of
          Just (lo,hi) -> TypeAtom (integer lo <> D.text ".." <> integer hi)
          Nothing -> TypeCall (if n == "BigUInt" then "non_neg_integer" else "integer") []
        Boolean -> TypeCall "boolean" []
        Floating -> TypeCall ":lawspec_beam_scalar.ieee" []
        Complex -> TypeCall ":lawspec_beam_scalar.complex" []
        Exact -> TypeCall (":lawspec_beam_scalar." ++ map toLower n) []
        Character -> TypeCall "non_neg_integer" []
        Sequence -> if n `elem` ["Text","Bytes"] then TypeCall "binary" [] else TypeContainer "[" [TypeCall "non_neg_integer" []] "]"
        Identity -> TypeCall ":lawspec_beam_scalar.symbol" []
        Absence -> TypeAtom (atom (case n of "Unit" -> "ok"; "Null" -> "null"; _ -> "undefined"))
      _ -> maybe (Left ("no Elixir native type: " ++ n))
        (\name -> pure (TypeCall ("LawSpec.Data." ++ name) ts)) (lookup (C.Id n) names)
  C.Arrow _ _ -> Left "function-valued Elixir data is unsupported"
  where
    argument (C.TypeArgument t) = nativeTypeLayout bits names parameters t
    argument (C.IndexArgument _) = Left "unerased Elixir type index"
    union = TypeUnion

-- | Elixir variables for source names, snake_case, unique in order; a
-- reserved word gets a trailing underscore.
variables :: [String] -> [String]
variables = fst . claimAll (scopeWith reserved) . map name
  where
    reserved = words "after alias and case catch cond def defmodule do else end false fn for if import in nil not or quote raise receive require rescue super true try unless unquote use when with"
    name source = let n = nativeIdentifier "elixir" ValueName source in if n `elem` reserved then n ++ "_" else n
